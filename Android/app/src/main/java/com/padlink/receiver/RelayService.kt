package com.padlink.receiver

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import rikka.shizuku.Shizuku

/** What the screen shows; written by [RelayService], read by [MainActivity]. */
object Relay {
    @Volatile var running = false
    @Volatile var state = "idle"
    @Volatile var packets = 0L
    @Volatile var phoneIp = ""
    @Volatile var message = ""
}

/**
 * Foreground service: starts the Shizuku helper (which owns the socket and the virtual pad), announces the
 * receiver over Bonjour so the iPhone finds it, and keeps Wi-Fi in its low-latency mode.
 */
class RelayService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var helper: IGamepadService? = null
    private var nsd: NsdManager? = null
    private var nsdListener: NsdManager.RegistrationListener? = null
    private var multicast: WifiManager.MulticastLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var bound = false

    private val args by lazy {
        Shizuku.UserServiceArgs(ComponentName(packageName, GamepadUserService::class.java.name))
            .daemon(false).processNameSuffix("padlink").debuggable(false).version(SERVICE_VERSION)
    }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            helper = IGamepadService.Stub.asInterface(binder)
            startRelay()
        }

        override fun onServiceDisconnected(name: ComponentName) {
            helper = null
            Relay.state = "idle"
            Relay.message = "The Shizuku helper stopped. Start PadLink again."
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (Relay.running) return START_STICKY
        startInForeground()
        Relay.running = true
        Relay.state = "idle"
        Relay.packets = 0
        Relay.phoneIp = ""
        Relay.message = "Starting…"
        when {
            !Shizuku.pingBinder() -> fail("Shizuku is not running. Open Shizuku and start it first.")
            Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED -> fail("PadLink does not have Shizuku permission yet.")
            else -> {
                try {
                    Shizuku.bindUserService(args, connection)
                    bound = true
                } catch (t: Throwable) {
                    fail("Could not start the Shizuku helper: ${t.message}")
                }
            }
        }
        return START_STICKY
    }

    private fun fail(message: String) {
        Relay.message = message
        stopSelf()
    }

    private fun startRelay() {
        val code = getSharedPreferences("padlink", MODE_PRIVATE).getString("code", "") ?: ""
        val ok = try {
            helper?.start(Protocol.PORT, code) ?: false
        } catch (t: Throwable) {
            false
        }
        if (!ok) {
            val err = try { helper?.status()?.split(";")?.getOrNull(3) } catch (t: Throwable) { null }
            fail(if (err.isNullOrBlank()) "Could not start the receiver." else err)
            return
        }
        acquireLocks()
        advertise()
        poll()
    }

    private fun poll() {
        val parts = try { helper?.status()?.split(";") } catch (t: Throwable) { null }
        if (parts != null && parts.size >= 4) {
            Relay.state = parts[0]
            Relay.packets = parts[1].toLongOrNull() ?: 0
            Relay.phoneIp = parts[2]
            Relay.message = parts[3]
            if (parts[3].isNotBlank()) {
                stopSelf()
                return
            }
            notify(
                when (parts[0]) {
                    "connected" -> "iPhone connected"
                    "listening" -> "Waiting for the iPhone"
                    else -> "Starting…"
                },
            )
        }
        handler.postDelayed({ poll() }, 500)
    }

    private fun acquireLocks() {
        try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicast = wm.createMulticastLock("padlink").apply { setReferenceCounted(false); acquire() }
            val mode = if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
            wifiLock = wm.createWifiLock(mode, "padlink").apply { setReferenceCounted(false); acquire() }
        } catch (_: Exception) {
        }
    }

    private fun advertise() {
        try {
            val manager = getSystemService(Context.NSD_SERVICE) as NsdManager
            val info = NsdServiceInfo().apply {
                serviceName = Build.MODEL
                serviceType = "_padlink._udp"
                port = Protocol.PORT
            }
            val listener = object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(info: NsdServiceInfo) {}
                override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) {}
                override fun onServiceUnregistered(info: NsdServiceInfo) {}
                override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {}
            }
            manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
            nsd = manager
            nsdListener = listener
        } catch (_: Exception) {
        }
    }

    private fun startInForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "PadLink receiver", NotificationManager.IMPORTANCE_LOW))
        }
        val n = buildNotification("Starting…")
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(
            this, 1, Intent(this, RelayService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_more)
            .setContentTitle("PadLink")
            .setContentText(text)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stop).build())
            .setOngoing(true)
            .build()
    }

    private fun notify(text: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification(text))
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        try { helper?.stop() } catch (_: Throwable) {}
        helper = null
        if (bound) {
            try { Shizuku.unbindUserService(args, connection, true) } catch (_: Throwable) {}
            bound = false
        }
        try { nsdListener?.let { nsd?.unregisterService(it) } } catch (_: Exception) {}
        try { multicast?.release() } catch (_: Exception) {}
        try { wifiLock?.release() } catch (_: Exception) {}
        Relay.running = false
        Relay.state = "idle"
        super.onDestroy()
    }

    companion object {
        const val ACTION_STOP = "com.padlink.receiver.STOP"
        private const val CHANNEL = "relay"
        private const val NOTIFICATION_ID = 1
        private const val SERVICE_VERSION = 1
    }
}
