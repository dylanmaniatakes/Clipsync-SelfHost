package com.bunty.clipsync

import android.app.Application

class ClipSyncApp : Application() {
    override fun onCreate() {
        super.onCreate()
        DeviceManager.getDeviceId(this)
    }
}
