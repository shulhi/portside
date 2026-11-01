package app.portside.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import app.portside.core.*
import kotlinx.coroutines.*

private val Teal = Color(0xFF197B66)

class MainActivity : ComponentActivity() {
    private val app get() = application as PortsideApplication
    private var permissionAction: (() -> Unit)? = null
    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        val action = permissionAction
        permissionAction = null
        if (checkSelfPermission(Manifest.permission.ACCESS_LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED) action?.invoke()
        else app.report("Allow nearby/local network access to connect to your Tailscale server. You can enable it in Android app permissions.")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val dark = isSystemInDarkTheme()
            MaterialTheme(colorScheme = if (dark) darkColorScheme(primary = Color(0xFF82D6BC), secondary = Color(0xFFB3CCBF))
                else lightColorScheme(primary = Teal, secondary = Color(0xFF4D635A), surface = Color(0xFFF8FAF8))) {
                val state by app.state.collectAsStateWithLifecycle()
                PortsideScreen(state, app,
                    onCheck = { server -> networkAction(false) { check(server) } },
                    onStart = { rule -> networkAction(true) {
                        runCatching { ForwardService.start(this, rule.id) }.onFailure { app.report("Could not start forwarding: ${it.message}") }
                    } },
                    onStop = { rule -> ForwardService.stop(this, rule.id) },
                    onOpen = { rule ->
                        runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(rule.browserUrl))) }
                            .onFailure { app.report("No web browser is available to open this forward.") }
                    })
            }
        }
    }

    private fun networkAction(forwarding: Boolean, action: () -> Unit) {
        val needed = buildList {
            if (checkSelfPermission(Manifest.permission.ACCESS_LOCAL_NETWORK) != PackageManager.PERMISSION_GRANTED) add(Manifest.permission.ACCESS_LOCAL_NETWORK)
            if (forwarding && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (needed.isEmpty()) action() else { permissionAction = action; permissions.launch(needed.toTypedArray()) }
    }
    private fun check(server: ServerProfile) {
        val requestId = java.util.UUID.randomUUID().toString()
        app.serverStatus(server.id, ServerStatus(checking = true, requestId = requestId))
        val revision = app.revision
        lifecycleScope.launch {
            try {
                val info = withContext(Dispatchers.IO) { app.info(server, app.store.token(server.id)) }
                if (revision == app.revision) app.serverStatus(server.id, ServerStatus(version = info.version))
            } catch (e: CancellationException) {
                if (revision == app.revision) app.serverStatus(server.id, ServerStatus())
                throw e
            }
            catch (e: Exception) {
                if (revision == app.revision) app.serverStatus(server.id, ServerStatus(error = e.message ?: "Check Tailscale and the server."))
            } finally {
                if (app.state.value.serverStatuses[server.id]?.requestId == requestId) {
                    app.serverStatus(server.id, ServerStatus())
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PortsideScreen(
    state: AppState, app: PortsideApplication,
    onCheck: (ServerProfile) -> Unit, onStart: (ForwardRule) -> Unit,
    onStop: (ForwardRule) -> Unit, onOpen: (ForwardRule) -> Unit,
) {
    var showServer by rememberSaveable { mutableStateOf(false) }
    var editingServerId by rememberSaveable { mutableStateOf<String?>(null) }
    var showForward by rememberSaveable { mutableStateOf(false) }
    var editingForwardId by rememberSaveable { mutableStateOf<String?>(null) }
    val editingServer = state.configuration.servers.firstOrNull { it.id == editingServerId }
    val editingForward = state.configuration.forwards.firstOrNull { it.id == editingForwardId }
    var removingServer by remember { mutableStateOf<ServerProfile?>(null) }
    var removingForward by remember { mutableStateOf<ForwardRule?>(null) }
    var serverMenu by remember { mutableStateOf(false) }
    val server = state.configuration.servers.firstOrNull { it.id == state.selectedServerId }
    val rules = state.configuration.forwards.filter { it.serverId == server?.id }
    val active = rules.count { state.snapshots[it.id]?.phase == Phase.LISTENING }
    val connections = rules.sumOf { state.snapshots[it.id]?.connections ?: 0 }

    Scaffold(
        topBar = {
            TopAppBar(title = {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(painterResource(R.drawable.ic_north_east), null, tint = MaterialTheme.colorScheme.primary)
                    Text("Portside", fontWeight = FontWeight.SemiBold)
                }
            }, actions = {
                IconButton(onClick = { editingServerId = null; showServer = true }) { Icon(Icons.Rounded.Add, "Add server") }
            })
        },
        floatingActionButton = {
            if (server != null) ExtendedFloatingActionButton(onClick = { editingForwardId = null; showForward = true },
                icon = { Icon(Icons.Rounded.Add, null) }, text = { Text("New forward") })
        },
    ) { insets ->
        LazyColumn(Modifier.fillMaxSize().padding(insets).widthIn(max = 760.dp),
            contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 104.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)) {
            item {
                Text("Your remote apps. On this phone.", style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (server == null) {
                item {
                    OutlinedCard(Modifier.fillMaxWidth(), shape = RoundedCornerShape(24.dp)) {
                        Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                            Icon(painterResource(R.drawable.ic_server), null, Modifier.size(32.dp), tint = MaterialTheme.colorScheme.primary)
                            Text("Connect your work server", style = MaterialTheme.typography.titleLarge)
                            Text("Keep Tailscale connected on both devices, then add the server running Portside.")
                            Button(onClick = { editingServerId = null; showServer = true }) { Text("Add server") }
                        }
                    }
                }
            } else {
                item {
                    val status = state.serverStatuses[server.id] ?: ServerStatus()
                    OutlinedCard(Modifier.fillMaxWidth(), shape = RoundedCornerShape(24.dp)) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(painterResource(R.drawable.ic_server), null, tint = MaterialTheme.colorScheme.primary)
                                Spacer(Modifier.width(12.dp))
                                Box(Modifier.weight(1f)) {
                                    TextButton(onClick = { serverMenu = true }, contentPadding = PaddingValues(0.dp)) {
                                        Text(server.name, style = MaterialTheme.typography.titleMedium, maxLines = 1)
                                        Icon(Icons.Rounded.KeyboardArrowDown, null)
                                    }
                                    DropdownMenu(serverMenu, { serverMenu = false }) {
                                        state.configuration.servers.forEach { profile ->
                                            DropdownMenuItem(text = { Text(profile.name) }, onClick = { app.selectServer(profile.id); serverMenu = false })
                                        }
                                        HorizontalDivider()
                                        DropdownMenuItem(text = { Text("Edit server") }, onClick = { editingServerId = server.id; showServer = true; serverMenu = false })
                                        DropdownMenuItem(text = { Text("Remove server") }, onClick = { removingServer = server; serverMenu = false })
                                    }
                                }
                                FilledTonalIconButton(onClick = { onCheck(server) }, enabled = !status.checking) {
                                    if (status.checking) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                                    else Icon(Icons.Rounded.Refresh, "Check connection")
                                }
                            }
                            Text("${server.host}:${server.port}", style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
                            if (status.version != null) Text("Ready · server ${status.version}", style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.primary)
                            else Text(status.error ?: "Check the connection to verify this server.", style = MaterialTheme.typography.bodySmall,
                                color = if (status.error != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                item {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text("Port forwards", style = MaterialTheme.typography.titleMedium)
                        Text("$active active · $connections connections", style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                if (rules.isEmpty()) item {
                    Text("Add an app port, start the forward, and open it in your browser.", style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 20.dp))
                }
                items(rules, key = { it.id }) { rule ->
                    ForwardCard(rule, state.snapshots[rule.id] ?: ForwardSnapshot(),
                        onStart = { onStart(rule) }, onStop = { onStop(rule) }, onOpen = { onOpen(rule) },
                        onEdit = { editingForwardId = rule.id; showForward = true }, onRemove = { removingForward = rule })
                }
                item {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Icon(Icons.Rounded.Lock, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text("Listeners stay on this phone. Traffic travels through Tailscale. Active forwards appear in a notification.",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
    if (showServer) ServerEditor(editingServer, onDismiss = { showServer = false }, onSave = { profile, token -> app.saveServer(profile, token) })
    if (showForward && server != null) ForwardEditor(server, editingForward, onDismiss = { showForward = false }, onSave = app::saveForward)
    removingForward?.let { rule ->
        ConfirmRemoval("Remove ${rule.name}?", "Its listener and active connections will close.", { removingForward = null }) {
            runCatching { app.removeForward(rule.id) }.onFailure { app.report(it.message) }; removingForward = null
        }
    }
    removingServer?.let { profile ->
        ConfirmRemoval("Remove ${profile.name}?", "This removes its token and forwards, and closes their connections.", { removingServer = null }) {
            runCatching { app.removeServer(profile.id) }.onFailure { app.report(it.message) }; removingServer = null
        }
    }
    state.error?.let { message ->
        AlertDialog(onDismissRequest = { app.report(null) }, title = { Text("Something needs attention") }, text = { Text(message) },
            confirmButton = { TextButton(onClick = { app.report(null) }) { Text("OK") } })
    }
}

@Composable
private fun ForwardCard(rule: ForwardRule, snapshot: ForwardSnapshot, onStart: () -> Unit, onStop: () -> Unit,
    onOpen: () -> Unit, onEdit: () -> Unit, onRemove: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val listening = snapshot.phase == Phase.LISTENING
    val starting = snapshot.phase == Phase.STARTING
    Card(Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(rule.name, style = MaterialTheme.typography.titleMedium)
                    Text(when (snapshot.phase) {
                        Phase.LISTENING -> "Listening · ${snapshot.connections} connections"
                        Phase.STARTING -> "Starting…"
                        Phase.FAILED -> "Failed"
                        Phase.STOPPED -> "Stopped"
                    }, style = MaterialTheme.typography.labelSmall,
                        color = if (listening) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                }
                IconButton(onClick = onOpen, enabled = listening) { Icon(painterResource(R.drawable.ic_browser), "Open ${rule.name} in browser") }
                Box {
                    IconButton(onClick = { menu = true }) { Icon(Icons.Rounded.MoreVert, "Actions for ${rule.name}") }
                    DropdownMenu(menu, { menu = false }) {
                        DropdownMenuItem(text = { Text("Edit forward") }, onClick = { menu = false; onEdit() })
                        DropdownMenuItem(text = { Text("Remove forward") }, onClick = { menu = false; onRemove() })
                    }
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("${rule.localPort}", fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodyMedium)
                Icon(Icons.AutoMirrored.Rounded.ArrowForward, null, Modifier.size(16.dp))
                Text("${rule.remotePort}", fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.weight(1f))
                OutlinedButton(onClick = if (listening || starting) onStop else onStart, contentPadding = PaddingValues(horizontal = 18.dp, vertical = 8.dp)) {
                    Text(if (starting) "Cancel" else if (listening) "Stop" else "Start")
                }
            }
            snapshot.error?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
        }
    }
}

@Composable
private fun ServerEditor(existing: ServerProfile?, onDismiss: () -> Unit, onSave: (ServerProfile, String) -> Unit) {
    var name by rememberSaveable { mutableStateOf(existing?.name ?: "") }
    var host by rememberSaveable { mutableStateOf(existing?.host ?: "") }
    var port by rememberSaveable { mutableStateOf(existing?.port?.toString() ?: "9417") }
    var token by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text(if (existing == null) "Add server" else "Edit server") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true)
            OutlinedTextField(host, { host = it }, label = { Text("Tailscale host") }, placeholder = { Text("work-laptop or 100.x.y.z") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
            OutlinedTextField(port, { port = it }, label = { Text("Server port") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
            OutlinedTextField(token, { token = it }, label = { Text(if (existing == null) "Server token" else "Replacement token (optional)") }, singleLine = true,
                visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
            Text(if (existing == null) "Tokens are encrypted with Android Keystore." else "Leave the token blank to keep it. Saving stops this server’s forwards.",
                style = MaterialTheme.typography.bodySmall)
            error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        }
    }, dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } }, confirmButton = {
        TextButton(onClick = {
            try {
                val parsed = port.toIntOrNull() ?: error("Enter a valid server port.")
                val server = ServerProfile(id = existing?.id ?: java.util.UUID.randomUUID().toString(), name = name.trim(), host = host.trim(), port = parsed)
                onSave(server, token.trim()); onDismiss()
            } catch (e: Exception) { error = e.message }
        }) { Text("Save server") }
    })
}

@Composable
private fun ForwardEditor(server: ServerProfile, existing: ForwardRule?, onDismiss: () -> Unit, onSave: (ForwardRule) -> Unit) {
    var name by rememberSaveable { mutableStateOf(existing?.name ?: "") }
    var local by rememberSaveable { mutableStateOf(existing?.localPort?.toString() ?: "3000") }
    var remote by rememberSaveable { mutableStateOf(existing?.remotePort?.toString() ?: "3000") }
    var ipv6 by rememberSaveable { mutableStateOf(existing?.family == "ipv6") }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text(if (existing == null) "New forward" else "Edit forward") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(server.name, style = MaterialTheme.typography.labelLarge)
            OutlinedTextField(name, { name = it }, label = { Text("Name") }, placeholder = { Text("Web app") }, singleLine = true)
            OutlinedTextField(local, { local = it }, label = { Text("Local port on this phone") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
            OutlinedTextField(remote, { remote = it }, label = { Text("App port on server") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("IPv6 server loopback", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                Switch(ipv6, { ipv6 = it })
            }
            Text("Open http://127.0.0.1:$local on this phone after starting. Saving leaves this forward stopped.", style = MaterialTheme.typography.bodySmall)
            error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        }
    }, dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } }, confirmButton = {
        TextButton(onClick = {
            try {
                val localPort = local.toIntOrNull() ?: error("Enter a valid local port.")
                val remotePort = remote.toIntOrNull() ?: error("Enter a valid remote port.")
                onSave(ForwardRule(id = existing?.id ?: java.util.UUID.randomUUID().toString(), serverId = server.id,
                    name = name.trim(), localPort = localPort, remotePort = remotePort, family = if (ipv6) "ipv6" else "ipv4"))
                onDismiss()
            } catch (e: Exception) { error = e.message }
        }) { Text("Save forward") }
    })
}

@Composable
private fun ConfirmRemoval(title: String, message: String, dismiss: () -> Unit, remove: () -> Unit) {
    AlertDialog(onDismissRequest = dismiss, title = { Text(title) }, text = { Text(message) },
        dismissButton = { TextButton(onClick = dismiss) { Text("Cancel") } },
        confirmButton = { TextButton(onClick = remove) { Text("Remove", color = MaterialTheme.colorScheme.error) } })
}
