package app.utsuripanel;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Opens the panel when the phone has booted. */
public final class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {
            context.startActivity(new Intent(context, PanelActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        }
    }
}
