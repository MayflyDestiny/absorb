package com.ryanheise.audioservice;

import android.content.Context;
import android.content.Intent;
import android.view.KeyEvent;

public class MediaButtonReceiver extends androidx.media.session.MediaButtonReceiver {
    public static final String ACTION_NOTIFICATION_DELETE = "com.ryanheise.audioservice.intent.action.ACTION_NOTIFICATION_DELETE";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent != null
                && ACTION_NOTIFICATION_DELETE.equals(intent.getAction())
                && AudioService.instance != null) {
            AudioService.instance.handleDeleteNotification();
            return;
        }
        // Absorb patch: intercept BYPASS keycodes BEFORE super.onReceive.
        // The platform's dispatchMediaKeyEvent swallows KEYCODE_MUTE (91) on
        // some ROMs, so we handle play/pause here and never let the system
        // touch these keycodes.
        if (intent != null
                && Intent.ACTION_MEDIA_BUTTON.equals(intent.getAction())
                && AudioService.instance != null) {
            @SuppressWarnings("deprecation")
            final KeyEvent event = (KeyEvent)intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT);
            if (event != null
                    && event.getAction() == KeyEvent.ACTION_DOWN
                    && (event.getKeyCode() == AudioService.KEYCODE_BYPASS_PLAY
                        || event.getKeyCode() == AudioService.KEYCODE_BYPASS_PAUSE)) {
                AudioService.instance.dispatchBypassKey(event.getKeyCode());
                return;
            }
        }
        super.onReceive(context, intent);
    }
}
