package app.portside.android

import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.IBinder
import app.portside.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

class ForwardService : Service() {
    private val app get() = application as PortsideApplication
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val starts = mutableMapOf<String, Job>()
    private var commanded = false
    private var destroyed = false

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "Active port forwards", NotificationManager.IMPORTANCE_LOW))
        scope.launch {
            app.state.map { it.snapshots.mapValues { entry -> entry.value.phase } }
                .distinctUntilChanged().collect { if (commanded) refresh() }
        }
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        commanded = true
        when (intent?.action) {
            START -> {
                try {
                    check(checkSelfPermission(Manifest.permission.ACCESS_LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED) {
                        "Allow local network access before starting a forward."
                    }
                    startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
                    val id = intent.getStringExtra(RULE) ?: error("Choose a forward.")
                    if (!starts.containsKey(id)) start(id)
                } catch (e: Exception) { app.report(e.message ?: "Could not start background forwarding."); refresh() }
            }
            STOP -> {
                val id = intent.getStringExtra(RULE)
                if (id != null) { starts.remove(id)?.cancel(); app.engine.stop(id) }
                refresh()
            }
            else -> { starts.values.toList().forEach(Job::cancel); starts.clear(); app.engine.stopAll(); refresh() }
        }
        return START_NOT_STICKY
    }
    private fun start(id: String) {
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                val config = app.state.value.configuration
                val rule = config.forwards.firstOrNull { it.id == id } ?: error("This forward was removed.")
                val server = config.servers.first { it.id == rule.serverId }
                val revision = app.revision
                val token = app.store.token(server.id)
                val info = withContext(Dispatchers.IO) { app.info(server, token) }
                check(revision == app.revision) { "Settings changed. Start this forward again." }
                check(info.allows(rule.remotePort)) { "The server does not allow this remote port." }
                app.serverStatus(server.id, ServerStatus(version = info.version))
                app.engine.start(rule, server, token)
            } catch (e: CancellationException) {
                if (starts[id] === currentCoroutineContext()[Job]) app.engine.stop(id)
                throw e
            } catch (e: Exception) {
                app.snapshot(id, ForwardSnapshot(Phase.FAILED, error = e.message ?: "Check Tailscale and your server."))
            } finally {
                if (starts[id] === currentCoroutineContext()[Job]) starts.remove(id)
                refresh()
            }
        }
        starts[id] = job
        app.snapshot(id, ForwardSnapshot(Phase.STARTING))
        job.start()
    }
    private fun refresh() {
        if (destroyed) return
        if (starts.isEmpty() && app.engine.activeCount == 0) {
            stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
        } else {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification())
        }
    }
    private fun notification(): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, ForwardService::class.java).setAction(STOP_ALL), PendingIntent.FLAG_IMMUTABLE)
        val count = app.engine.activeCount
        return Notification.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_forward)
            .setContentTitle(if (count == 0) "Starting port forward…" else "$count active ${if (count == 1) "forward" else "forwards"}")
            .setContentText("Remote apps are available on this phone’s localhost.")
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null, "Stop all", stop).build()).build()
    }
    override fun onDestroy() {
        destroyed = true
        starts.clear()
        scope.cancel(); app.engine.stopAll()
        super.onDestroy()
    }
    override fun onTimeout(startId: Int, fgsType: Int) { app.engine.stopAll(); stopSelf() }

    companion object {
        const val START = "app.portside.START"
        const val STOP = "app.portside.STOP"
        const val STOP_ALL = "app.portside.STOP_ALL"
        const val RULE = "rule"
        private const val CHANNEL = "portside-forwards"
        private const val NOTIFICATION = 1
        fun start(context: Context, id: String) {
            context.startForegroundService(Intent(context, ForwardService::class.java).setAction(START).putExtra(RULE, id))
        }
        fun stop(context: Context, id: String) {
            context.startService(Intent(context, ForwardService::class.java).setAction(STOP).putExtra(RULE, id))
        }
    }
}
