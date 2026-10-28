package com.padlink.receiver

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import rikka.shizuku.Shizuku

class MainActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var status: TextView
    private lateinit var detail: TextView
    private lateinit var action: Button
    private lateinit var shizukuButton: Button
    private lateinit var code: EditText

    private val permissionListener = Shizuku.OnRequestPermissionResultListener { _, _ -> refresh() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = BG
        window.navigationBarColor = BG
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(40), dp(20), dp(24))
        }
        root.addView(text("PadLink", 30f, TEXT, bold = true))
        root.addView(text("Receiver for Android", 15f, MUTED))

        val card = card()
        status = text("", 18f, TEXT, bold = true)
        detail = text("", 14f, MUTED)
        card.addView(status)
        card.addView(detail)
        root.addView(card)

        val pairing = card()
        pairing.addView(text("PAIRING CODE (OPTIONAL)", 12f, MUTED, bold = true))
        code = EditText(this).apply {
            setTextColor(TEXT)
            setHintTextColor(MUTED)
            hint = "Same code as the one shown on the PC, or leave empty"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            setText(getSharedPreferences("padlink", MODE_PRIVATE).getString("code", ""))
        }
        pairing.addView(code)
        pairing.addView(text("If you set a code here, type the same one in the iPhone app under PC.", 12f, MUTED))
        root.addView(pairing)

        action = button("Start", TEAL).apply { setOnClickListener { onAction() } }
        shizukuButton = button("Open Shizuku", MUTED).apply { setOnClickListener { openShizuku() } }
        root.addView(action)
        root.addView(shizukuButton)
        root.addView(
            text(
                "How it works: Shizuku lets PadLink create a virtual Xbox-style controller without root. " +
                    "Start Shizuku once after each reboot (Wireless debugging), press Start here, and the iPhone app finds this device by itself.",
                12f, MUTED,
            ).apply { setPadding(0, dp(16), 0, 0) },
        )

        setContentView(ScrollView(this).apply { setBackgroundColor(BG); addView(root) })

        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2)
        }
        Shizuku.addRequestPermissionResultListener(permissionListener)
    }

    override fun onResume() {
        super.onResume()
        tick()
    }

    override fun onPause() {
        handler.removeCallbacksAndMessages(null)
        super.onPause()
    }

    override fun onDestroy() {
        Shizuku.removeRequestPermissionResultListener(permissionListener)
        super.onDestroy()
    }

    private fun tick() {
        refresh()
        handler.postDelayed({ tick() }, 500)
    }

    private fun shizukuInstalled(): Boolean = try {
        packageManager.getPackageInfo("moe.shizuku.privileged.api", 0)
        true
    } catch (_: Exception) {
        false
    }

    private fun granted(): Boolean = try {
        Shizuku.pingBinder() && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
    } catch (_: Throwable) {
        false
    }

    private fun refresh() {
        val ip = localIp()
        if (Relay.running) {
            action.text = "Stop"
            tint(action, RED)
            shizukuButton.visibility = View.GONE
            when (Relay.state) {
                "connected" -> {
                    status.text = "Connected"
                    detail.text = "iPhone ${Relay.phoneIp} · ${Relay.packets} packets"
                }
                "listening" -> {
                    status.text = "Waiting for the iPhone"
                    detail.text = "Open PadLink on the iPhone. It finds this device automatically." + (if (ip.isNotEmpty()) " If not, enter $ip in the app." else "")
                }
                else -> {
                    status.text = "Starting…"
                    detail.text = Relay.message
                }
            }
            return
        }
        action.text = "Start"
        tint(action, TEAL)
        shizukuButton.visibility = View.VISIBLE
        when {
            !shizukuInstalled() -> {
                status.text = "Shizuku is needed"
                detail.text = "Install Shizuku (free) from its website, then start it with Wireless debugging."
                shizukuButton.text = "Get Shizuku"
            }
            !(try { Shizuku.pingBinder() } catch (_: Throwable) { false }) -> {
                status.text = "Shizuku is not running"
                detail.text = "Open Shizuku and start it. It needs a restart after every reboot."
                shizukuButton.text = "Open Shizuku"
            }
            !granted() -> {
                status.text = "Permission needed"
                detail.text = "Press Start and allow PadLink in the Shizuku prompt."
                shizukuButton.text = "Open Shizuku"
            }
            else -> {
                status.text = "Ready"
                detail.text = if (Relay.message.isNotBlank()) Relay.message else "Press Start."
                shizukuButton.text = "Open Shizuku"
            }
        }
    }

    private fun onAction() {
        if (Relay.running) {
            startService(Intent(this, RelayService::class.java).setAction(RelayService.ACTION_STOP))
            return
        }
        if (!(try { Shizuku.pingBinder() } catch (_: Throwable) { false })) {
            openShizuku()
            return
        }
        if (!granted()) {
            try { Shizuku.requestPermission(1) } catch (_: Throwable) {}
            return
        }
        getSharedPreferences("padlink", MODE_PRIVATE).edit().putString("code", code.text.toString()).apply()
        Relay.message = ""
        startForegroundService(Intent(this, RelayService::class.java))
    }

    private fun openShizuku() {
        val launch = packageManager.getLaunchIntentForPackage("moe.shizuku.privileged.api")
        startActivity(launch ?: Intent(Intent.ACTION_VIEW, Uri.parse("https://shizuku.rikka.app/download/")))
    }

    @Suppress("DEPRECATION")
    private fun localIp(): String = try {
        val ip = (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).connectionInfo.ipAddress
        if (ip == 0) "" else "${ip and 0xFF}.${ip shr 8 and 0xFF}.${ip shr 16 and 0xFF}.${ip shr 24 and 0xFF}"
    } catch (_: Exception) {
        ""
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun text(s: String, size: Float, color: Int, bold: Boolean = false) = TextView(this).apply {
        text = s
        textSize = size
        setTextColor(color)
        if (bold) setTypeface(null, Typeface.BOLD)
    }

    private fun card() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(16), dp(16), dp(16), dp(16))
        background = GradientDrawable().apply { setColor(CARD); cornerRadius = dp(16).toFloat(); setStroke(dp(1), BORDER) }
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(16) }
    }

    private fun button(label: String, color: Int) = Button(this).apply {
        text = label
        isAllCaps = false
        textSize = 17f
        gravity = Gravity.CENTER
        layoutParams = LinearLayout.LayoutParams(-1, dp(56)).apply { topMargin = dp(16) }
        tint(this, color)
    }

    private fun tint(b: Button, color: Int) {
        b.setTextColor(color)
        b.background = GradientDrawable().apply { setColor(Color.TRANSPARENT); cornerRadius = dp(14).toFloat(); setStroke(dp(2), color) }
    }

    private companion object {
        val BG = Color.parseColor("#0D1321")
        val CARD = Color.parseColor("#161E32")
        val BORDER = Color.parseColor("#26304A")
        val TEXT = Color.parseColor("#F2F4F8")
        val MUTED = Color.parseColor("#9AA6BF")
        val TEAL = Color.parseColor("#35E0C2")
        val RED = Color.parseColor("#FF6B6B")
    }
}
