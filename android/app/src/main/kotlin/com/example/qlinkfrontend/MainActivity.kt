package com.example.qlinkfrontend

import io.flutter.embedding.android.FlutterActivity
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var shareInbox: ShareInbox? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        shareInbox = ShareInbox(this, flutterEngine.dartExecutor.binaryMessenger)
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) shareInbox?.accept(intent)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        shareInbox?.accept(intent)
    }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        shareInbox?.close()
        shareInbox = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
