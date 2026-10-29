use std::{
    path::{Component, Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use axum::{
    Json,
    body::Body,
    extract::{Query, State},
    http::{HeaderMap, StatusCode, header},
};
use cap_std::{
    ambient_authority,
    fs::{Dir, OpenOptions},
};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use tokio::{fs::File, io::AsyncWriteExt, time::timeout};

use crate::{ApiError, AppState};

pub(crate) struct UploadStore {
    root: Dir,
    path: PathBuf,
    limit: u64,
}

#[derive(Serialize)]
pub(crate) struct UploadInfo {
    directory: String,
    max_file_size: u64,
}

impl UploadStore {
    pub fn new(path: PathBuf, limit: u64) -> anyhow::Result<Self> {
        let mut builder = std::fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(&path)?;
        let path = std::fs::canonicalize(path)?;
        let root = Dir::open_ambient_dir(&path, ambient_authority())?;
        Ok(Self { root, path, limit })
    }

    pub fn info(&self) -> UploadInfo {
        UploadInfo {
            directory: self.path.to_string_lossy().into_owned(),
            max_file_size: self.limit,
        }
    }

    fn prepare(&self, name: &str, folder: &str) -> Result<(PendingFile, File), ApiError> {
        validate_name(name)?;
        validate_folder(folder)?;
        let folder = if folder.is_empty() {
            Path::new(".")
        } else {
            Path::new(folder)
        };
        self.root
            .create_dir_all(folder)
            .map_err(|_| directory_error())?;
        // cap-std resolves relative to a directory handle, including symlinks,
        // and refuses traversal outside that capability's root.
        let directory = self.root.open_dir(folder).map_err(|_| directory_error())?;
        let mut random = [0; 16];
        getrandom::fill(&mut random).map_err(|_| io_error())?;
        let id: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
        let seconds = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| io_error())?
            .as_secs();
        let temporary = format!(".portside-{id}.part");
        let filename = format!("{seconds}-{id}-{name}");
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use cap_std::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let file = directory
            .open_with(&temporary, &options)
            .map_err(|_| io_error())?;
        let destination = if folder == Path::new(".") {
            self.path.join(&filename)
        } else {
            self.path.join(folder).join(&filename)
        };
        Ok((
            PendingFile {
                directory,
                temporary,
                filename,
                destination,
            },
            File::from_std(file.into_std()),
        ))
    }
}

struct PendingFile {
    directory: Dir,
    temporary: String,
    filename: String,
    destination: PathBuf,
}

impl PendingFile {
    fn publish(self, name: String, bytes: u64) -> Result<UploadResult, ApiError> {
        // Creating a hard link publishes complete bytes atomically and fails
        // rather than replacing an existing destination, even on a collision.
        self.directory
            .hard_link(&self.temporary, &self.directory, &self.filename)
            .map_err(|_| io_error())?;
        Ok(UploadResult {
            name,
            path: self.destination.to_string_lossy().into_owned(),
            bytes,
        })
    }
}

impl Drop for PendingFile {
    fn drop(&mut self) {
        let _ = self.directory.remove_file(&self.temporary);
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct UploadQuery {
    filename: String,
    #[serde(default)]
    folder: String,
}

#[derive(Serialize)]
pub(crate) struct UploadResult {
    name: String,
    path: String,
    bytes: u64,
}

pub(crate) async fn upload(
    State(state): State<AppState>,
    Query(query): Query<UploadQuery>,
    headers: HeaderMap,
    body: Body,
) -> Result<(StatusCode, Json<UploadResult>), ApiError> {
    let store = state.uploads.clone().ok_or_else(|| {
        ApiError::new(
            StatusCode::NOT_FOUND,
            "uploads_disabled",
            "File uploads are disabled. Configure --upload-dir on the server.",
        )
    })?;
    validate_name(&query.filename)?;
    validate_folder(&query.folder)?;
    if headers
        .get(header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok())
        .is_some_and(|length| length > store.limit)
    {
        return Err(size_error());
    }
    let _permit = state
        .upload_capacity
        .clone()
        .try_acquire_owned()
        .map_err(|_| {
            ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "upload_capacity",
                "The server is receiving other files. Try again shortly.",
            )
        })?;
    let limit = store.limit;
    let filename = query.filename.clone();
    let (pending, mut file) =
        tokio::task::spawn_blocking(move || store.prepare(&query.filename, &query.folder))
            .await
            .map_err(|_| io_error())??;
    let mut stream = body.into_data_stream();
    let transfer = async {
        let mut bytes = 0u64;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|_| {
                ApiError::new(
                    StatusCode::BAD_REQUEST,
                    "incomplete_upload",
                    "The file transfer was interrupted.",
                )
            })?;
            bytes = bytes
                .checked_add(chunk.len() as u64)
                .ok_or_else(size_error)?;
            if bytes > limit {
                return Err(size_error());
            }
            file.write_all(&chunk).await.map_err(|_| io_error())?;
        }
        file.sync_all().await.map_err(|_| io_error())?;
        Ok::<u64, ApiError>(bytes)
    };
    let bytes = tokio::select! {
        _ = state.shutdown.cancelled() => return Err(ApiError::new(StatusCode::SERVICE_UNAVAILABLE, "shutting_down", "The server is shutting down.")),
        result = timeout(Duration::from_secs(600), transfer) => result.map_err(|_| ApiError::new(StatusCode::REQUEST_TIMEOUT, "upload_timeout", "The upload exceeded ten minutes."))??,
    };
    drop(file);
    let result = tokio::task::spawn_blocking(move || pending.publish(filename, bytes))
        .await
        .map_err(|_| io_error())??;
    Ok((StatusCode::CREATED, Json(result)))
}

fn validate_name(name: &str) -> Result<(), ApiError> {
    if name.is_empty()
        || name.len() > 180
        || name == "."
        || name == ".."
        || name
            .chars()
            .any(|c| c == '/' || c == '\\' || c.is_control())
    {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_filename",
            "Use a filename without path separators or control characters (maximum 180 UTF-8 bytes).",
        ));
    }
    Ok(())
}

fn validate_folder(folder: &str) -> Result<(), ApiError> {
    if folder.len() > 1024
        || folder.chars().any(|c| c == '\\' || c.is_control())
        || (!folder.is_empty()
            && folder
                .split('/')
                .any(|part| part.is_empty() || part == "." || part == ".."))
        || Path::new(folder)
            .components()
            .any(|part| !matches!(part, Component::Normal(_)))
    {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_folder",
            "Choose a relative upload subfolder without dot segments or path traversal.",
        ));
    }
    Ok(())
}

fn size_error() -> ApiError {
    ApiError::new(
        StatusCode::PAYLOAD_TOO_LARGE,
        "file_too_large",
        "This file exceeds the server's upload size limit.",
    )
}
fn io_error() -> ApiError {
    ApiError::new(
        StatusCode::INTERNAL_SERVER_ERROR,
        "upload_io",
        "The server could not save this file. Check directory permissions and free disk space.",
    )
}
fn directory_error() -> ApiError {
    ApiError::new(
        StatusCode::FORBIDDEN,
        "upload_directory",
        "This subfolder is unavailable or resolves outside the upload directory.",
    )
}
