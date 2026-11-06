package app.portside.android

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.portside.core.ServerIcon

val ServerIcon.title: String get() = when (this) {
    ServerIcon.SERVER -> "Server"
    ServerIcon.LAPTOP -> "Laptop"
    ServerIcon.DESKTOP -> "Desktop"
    ServerIcon.HOME -> "Home"
    ServerIcon.CLOUD -> "Cloud"
    ServerIcon.TERMINAL -> "Terminal"
}

val ServerIcon.drawable: Int get() = when (this) {
    ServerIcon.SERVER -> R.drawable.ic_server
    ServerIcon.LAPTOP -> R.drawable.ic_laptop
    ServerIcon.DESKTOP -> R.drawable.ic_desktop
    ServerIcon.HOME -> R.drawable.ic_home
    ServerIcon.CLOUD -> R.drawable.ic_cloud
    ServerIcon.TERMINAL -> R.drawable.ic_terminal
}

@Composable
fun ServerIconPicker(selected: ServerIcon, onSelect: (ServerIcon) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Server icon", style = MaterialTheme.typography.labelLarge)
        ServerIcon.entries.chunked(3).forEach { row ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { icon ->
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                        OutlinedIconToggleButton(checked = selected == icon, onCheckedChange = { onSelect(icon) }) {
                            Icon(painterResource(icon.drawable), "${icon.title} icon", Modifier.size(22.dp))
                        }
                        Text(icon.title, style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
        }
    }
}
