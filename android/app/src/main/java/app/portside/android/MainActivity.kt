package app.portside.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import app.portside.core.*
import kotlinx.coroutines.*

private val Blue = Color(0xFF1462D2)

class MainActivity : ComponentActivity() {
    private val app get() = application as PortsideApplication
    private var permissionAction: (() -> Unit)? = null
    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        val action = permissionAction
        permissionAction = null
        if (Build.VERSION.SDK_INT < 37 || checkSelfPermission(Manifest.permission.ACCESS_LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED) action?.invoke()
        else app.report("Allow nearby/local network access to connect to your Tailscale server. You can enable it in Android app permissions.")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT))
        setContent {
            MaterialTheme(colorScheme = lightColorScheme(
                    primary = Blue, onPrimary = Color.White,
                    primaryContainer = Color(0xFFD8E6FF), onPrimaryContainer = Color(0xFF001B3E),
                    secondary = Color(0xFF566172), secondaryContainer = Color(0xFFE1E7F0),
                    surface = Color(0xFFFAFBFE), background = Color(0xFFFAFBFE),
                    surfaceContainer = Color(0xFFF0F3F8), surfaceContainerLow = Color(0xFFF3F5FA))) {
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
            if (Build.VERSION.SDK_INT >= 37 && checkSelfPermission(Manifest.permission.ACCESS_LOCAL_NETWORK) != PackageManager.PERMISSION_GRANTED) add(Manifest.permission.ACCESS_LOCAL_NETWORK)
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
                val info = withContext(Dispatchers.IO) { app.info(server) }
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
    var forwardServerId by rememberSaveable { mutableStateOf<String?>(null) }
    var editingForwardId by rememberSaveable { mutableStateOf<String?>(null) }
    val editingServer = state.configuration.servers.firstOrNull { it.id == editingServerId }
    val editingForward = state.configuration.forwards.firstOrNull { it.id == editingForwardId }
    var removingServer by remember { mutableStateOf<ServerProfile?>(null) }
    var removingForward by remember { mutableStateOf<ForwardRule?>(null) }
    val servers = state.configuration.servers
    val forwardServer = servers.firstOrNull { it.id == forwardServerId }
    val active = state.configuration.forwards.count { state.snapshots[it.id]?.phase == Phase.LISTENING }

    Scaffold(topBar = {
        TopAppBar(title = {
            Column {
                Text("Portside", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                Text("${servers.size} ${if (servers.size == 1) "server" else "servers"} · $active active",
                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }, actions = {
            FilledTonalButton(onClick = { editingServerId = null; showServer = true },
                modifier = Modifier.padding(end = 12.dp), contentPadding = PaddingValues(horizontal = 12.dp)) {
                Icon(painterResource(R.drawable.ic_server_add), null, Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("Add server", style = MaterialTheme.typography.labelMedium)
            }
        })
    }) { insets ->
        Box(Modifier.fillMaxSize().padding(insets), contentAlignment = Alignment.TopCenter) {
            LazyColumn(Modifier.widthIn(max = 760.dp).fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp)) {
                if (servers.isEmpty()) item {
                    OutlinedCard(Modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp)) {
                        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text("Connect your work server", style = MaterialTheme.typography.titleMedium)
                            Text("Keep Tailscale connected on both devices, then add the server running Portside.",
                                style = MaterialTheme.typography.bodyMedium)
                            Button(onClick = { editingServerId = null; showServer = true }) { Text("Add server") }
                        }
                    }
                }
                servers.forEach { server ->
                    val rules = state.configuration.forwards.filter { it.serverId == server.id }
                    item(key = "server:${server.id}") {
                        ServerHeader(server, state.serverStatuses[server.id] ?: ServerStatus(),
                            active = rules.count { state.snapshots[it.id]?.phase == Phase.LISTENING },
                            canStop = rules.any { state.snapshots[it.id]?.phase in listOf(Phase.LISTENING, Phase.STARTING) },
                            onAdd = { editingForwardId = null; forwardServerId = server.id },
                            onCheck = { onCheck(server) },
                            onEdit = { editingServerId = server.id; showServer = true },
                            onRemove = { removingServer = server },
                            onStop = { rules.filter { state.snapshots[it.id]?.phase in listOf(Phase.LISTENING, Phase.STARTING) }.forEach(onStop) })
                    }
                    if (rules.isEmpty()) item(key = "empty:${server.id}") {
                        Text("No forwards", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(start = 12.dp, bottom = 8.dp))
                    }
                    items(rules, key = { "forward:${it.id}" }) { rule ->
                        val other = state.configuration.forwards.firstOrNull { candidate ->
                            candidate.id != rule.id && candidate.localPort == rule.localPort &&
                                state.snapshots[candidate.id]?.phase in listOf(Phase.STARTING, Phase.LISTENING)
                        }
                        val conflictingServer = servers.firstOrNull { it.id == other?.serverId }?.name
                        ForwardRow(rule, state.snapshots[rule.id] ?: ForwardSnapshot(), conflictingServer,
                            onStart = { onStart(rule) }, onStop = { onStop(rule) }, onOpen = { onOpen(rule) },
                            onEdit = { editingForwardId = rule.id; forwardServerId = rule.serverId },
                            onRemove = { removingForward = rule })
                    }
                    item(key = "spacing:${server.id}") { Spacer(Modifier.height(8.dp)) }
                }
            }
        }
    }
    if (showServer) ServerEditor(editingServer, onDismiss = { showServer = false }, onSave = app::saveServer)
    if (forwardServer != null) key(forwardServer.id, editingForwardId) {
        ForwardEditor(forwardServer, editingForward, onDismiss = { forwardServerId = null }, onSave = app::saveForward)
    }
    removingForward?.let { rule ->
        ConfirmRemoval("Remove ${rule.name}?", "Its listener and active connections will close.", { removingForward = null }) {
            runCatching { app.removeForward(rule.id) }.onFailure { app.report(it.message) }; removingForward = null
        }
    }
    removingServer?.let { profile ->
        ConfirmRemoval("Remove ${profile.name}?", "This removes its forwards and closes their connections.", { removingServer = null }) {
            runCatching { app.removeServer(profile.id) }.onFailure { app.report(it.message) }; removingServer = null
        }
    }
    state.error?.let { message ->
        AlertDialog(onDismissRequest = { app.report(null) }, title = { Text("Something needs attention") }, text = { Text(message) },
            confirmButton = { TextButton(onClick = { app.report(null) }) { Text("OK") } })
    }
}

@Composable
private fun ServerHeader(server: ServerProfile, status: ServerStatus, active: Int, canStop: Boolean,
    onAdd: () -> Unit, onCheck: () -> Unit, onEdit: () -> Unit, onRemove: () -> Unit, onStop: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(top = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onEdit) {
                if (status.checking) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                else Icon(painterResource(server.icon.drawable), "Edit ${server.name} icon", Modifier.size(22.dp),
                    tint = MaterialTheme.colorScheme.primary)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(server.name, style = MaterialTheme.typography.titleSmall, maxLines = 1,
                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    if (active > 0 || status.version != null) Text(if (active > 0) "$active active" else "Ready", style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary)
                }
                Text("${server.host}:${server.port}", style = MaterialTheme.typography.labelSmall, maxLines = 1,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            OutlinedButton(onClick = onAdd, contentPadding = PaddingValues(horizontal = 10.dp),
                modifier = Modifier.semantics { contentDescription = "Add forward to ${server.name}" }) {
                Text("Add forward", style = MaterialTheme.typography.labelMedium)
            }
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Rounded.MoreVert, "Actions for server ${server.name}", Modifier.size(20.dp)) }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem(text = { Text("Check connection") }, enabled = !status.checking,
                        onClick = { menu = false; onCheck() })
                    DropdownMenuItem(text = { Text("Edit server") }, onClick = { menu = false; onEdit() })
                    DropdownMenuItem(text = { Text("Stop forwards") }, enabled = canStop, onClick = { menu = false; onStop() })
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text("Remove server") }, onClick = { menu = false; onRemove() })
                }
            }
        }
        status.error?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(start = 12.dp, bottom = 4.dp))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ForwardRow(rule: ForwardRule, snapshot: ForwardSnapshot, conflictingServer: String?, onStart: () -> Unit, onStop: () -> Unit,
    onOpen: () -> Unit, onEdit: () -> Unit, onRemove: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val listening = snapshot.phase == Phase.LISTENING
    val starting = snapshot.phase == Phase.STARTING
    val status = when (snapshot.phase) {
        Phase.LISTENING -> "Listening · ${snapshot.connections} connections"
        Phase.STARTING -> "Starting…"
        Phase.FAILED -> "Failed"
        Phase.STOPPED -> conflictingServer?.let { "In use by $it" } ?: "Stopped"
    }
    Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow) {
        Column(Modifier.padding(start = 12.dp, end = 2.dp, top = 4.dp, bottom = 4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.padding(end = 10.dp).size(30.dp)
                    .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(8.dp))
                    .semantics { contentDescription = "Port ${rule.localPort}, $status" }) {
                    Icon(painterResource(R.drawable.ic_terminal), null, Modifier.align(Alignment.Center).size(18.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Box(Modifier.align(Alignment.BottomEnd).size(9.dp)
                        .background(if (listening) Color(0xFF219653) else if (snapshot.phase == Phase.FAILED)
                            MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.outlineVariant, CircleShape)
                        .border(1.5.dp, MaterialTheme.colorScheme.surfaceContainerLow, CircleShape))
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text("${rule.localPort}:${rule.remotePort}", fontFamily = FontFamily.Monospace,
                        style = MaterialTheme.typography.titleSmall)
                    Text("${rule.name} · $status", style = MaterialTheme.typography.labelSmall, maxLines = 1,
                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                val action = if (starting) "Cancel ${rule.name}" else if (listening) "Stop ${rule.name}"
                    else if (conflictingServer != null) "Switch to ${rule.name}" else "Start ${rule.name}"
                TooltipBox(positionProvider = TooltipDefaults.rememberTooltipPositionProvider(TooltipAnchorPosition.Above),
                    tooltip = { PlainTooltip { Text(action) } }, state = rememberTooltipState()) {
                    FilledTonalIconButton(onClick = if (listening || starting) onStop else onStart,
                        colors = IconButtonDefaults.filledTonalIconButtonColors(
                            containerColor = if (listening) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.primaryContainer,
                            contentColor = if (listening) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onPrimaryContainer)) {
                        when {
                            starting -> Icon(Icons.Rounded.Close, action, Modifier.size(18.dp))
                            listening -> Icon(painterResource(R.drawable.ic_stop), action, Modifier.size(18.dp))
                            conflictingServer != null -> Icon(painterResource(R.drawable.ic_forward), action, Modifier.size(18.dp))
                            else -> Icon(Icons.Rounded.PlayArrow, action, Modifier.size(20.dp))
                        }
                    }
                }
                Box {
                    IconButton(onClick = { menu = true }) { Icon(Icons.Rounded.MoreVert, "Actions for forward ${rule.name}", Modifier.size(20.dp)) }
                    DropdownMenu(menu, { menu = false }) {
                        DropdownMenuItem(text = { Text("Open in browser") }, enabled = listening, onClick = { menu = false; onOpen() })
                        DropdownMenuItem(text = { Text("Edit forward") }, onClick = { menu = false; onEdit() })
                        DropdownMenuItem(text = { Text("Remove forward") }, onClick = { menu = false; onRemove() })
                    }
                }
            }
            snapshot.error?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(end = 8.dp, top = 2.dp, bottom = 4.dp))
            }
        }
    }
}

@Composable
private fun ServerEditor(existing: ServerProfile?, onDismiss: () -> Unit, onSave: (ServerProfile) -> Unit) {
    var name by rememberSaveable { mutableStateOf(existing?.name ?: "") }
    var host by rememberSaveable { mutableStateOf(existing?.host ?: "") }
    var port by rememberSaveable { mutableStateOf(existing?.port?.toString() ?: "9417") }
    var iconName by rememberSaveable { mutableStateOf((existing?.icon ?: ServerIcon.SERVER).name) }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text(if (existing == null) "Add server" else "Edit server") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            ServerIconPicker(ServerIcon.valueOf(iconName), onSelect = { iconName = it.name })
            OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true)
            OutlinedTextField(host, { host = it }, label = { Text("Tailscale host") }, placeholder = { Text("work-laptop or 100.x.y.z") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
            OutlinedTextField(port, { port = it }, label = { Text("Server port") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
            Text(if (existing == null) "Access uses your existing Tailscale identity." else "Changing the server address stops its forwards. Name and icon changes keep them running.",
                style = MaterialTheme.typography.bodySmall)
            error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        }
    }, dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } }, confirmButton = {
        TextButton(onClick = {
            try {
                val parsed = port.toIntOrNull() ?: error("Enter a valid server port.")
                val server = ServerProfile(id = existing?.id ?: java.util.UUID.randomUUID().toString(), name = name.trim(), host = host.trim(), port = parsed,
                    icon = ServerIcon.valueOf(iconName))
                onSave(server); onDismiss()
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
            Text("Open http://127.0.0.1:$local on this phone after starting. Saving leaves this forward stopped. You can reuse a local port on another server; starting it switches that port and closes the previous connections.", style = MaterialTheme.typography.bodySmall)
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
