use std::{
    fs,
    path::PathBuf,
    process::{Command, Output},
};

fn temporary_token_path() -> PathBuf {
    let mut random = [0; 8];
    getrandom::fill(&mut random).unwrap();
    let suffix: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
    std::env::temp_dir().join(format!("portside-cli-{suffix}.token"))
}

fn generate(path: &PathBuf) -> Output {
    Command::new(env!("CARGO_BIN_EXE_portside-server"))
        .args(["generate-token", "--output"])
        .arg(path)
        .output()
        .unwrap()
}

#[test]
fn generated_credentials_are_private_and_never_overwritten_or_logged() {
    let path = temporary_token_path();
    let result = generate(&path);
    assert!(result.status.success());
    let secret = fs::read_to_string(&path).unwrap();
    assert_eq!(secret.trim().len(), 64);
    assert!(!String::from_utf8_lossy(&result.stdout).contains(secret.trim()));
    assert!(!String::from_utf8_lossy(&result.stderr).contains(secret.trim()));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    assert!(!generate(&path).status.success());
    assert_eq!(fs::read_to_string(&path).unwrap(), secret);
    fs::remove_file(path).unwrap();
}

#[test]
fn wildcard_bind_is_refused_at_startup() {
    let path = temporary_token_path();
    assert!(generate(&path).status.success());
    let result = Command::new(env!("CARGO_BIN_EXE_portside-server"))
        .args(["serve", "--listen", "0.0.0.0:9417", "--token-file"])
        .arg(&path)
        .output()
        .unwrap();
    assert!(!result.status.success());
    assert!(String::from_utf8_lossy(&result.stderr).contains("wildcard"));
    fs::remove_file(path).unwrap();
}

#[cfg(unix)]
#[test]
fn readable_by_other_users_token_file_is_refused() {
    use std::os::unix::fs::PermissionsExt;
    let path = temporary_token_path();
    assert!(generate(&path).status.success());
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    let result = Command::new(env!("CARGO_BIN_EXE_portside-server"))
        .args(["serve", "--token-file"])
        .arg(&path)
        .output()
        .unwrap();
    assert!(!result.status.success());
    assert!(String::from_utf8_lossy(&result.stderr).contains("chmod 600"));
    fs::remove_file(path).unwrap();
}
