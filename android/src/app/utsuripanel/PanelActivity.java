package app.utsuripanel;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.WindowManager;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

/**
 * The panel: the page the Mac serves (through adb reverse) full screen, kept
 * on, without any browser UI. While the Mac can't be reached it shows a
 * notice and retries.
 *
 * {@code adb shell am start -n app.utsuripanel/.PanelActivity -d <url>} opens
 * another URL (and reloads).
 */
public final class PanelActivity extends Activity {
    private static final String DEFAULT_URL = "http://localhost:26472/";
    private static final long RETRY_MS = 3000;
    private static final String OFFLINE_PAGE =
            "<html><body style='margin:0;height:100%;background:#000;display:flex;align-items:center;"
            + "justify-content:center;color:#8a94a6;font:5vh sans-serif'>Нет связи с Mac</body></html>";

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable reload = new Runnable() {
        @Override public void run() { web.loadUrl(url); }
    };
    private WebView web;
    private String url;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                | WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                | WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
                | WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON);
        WebView.setWebContentsDebuggingEnabled(true);  // chrome://inspect on the Mac

        web = new WebView(this);
        web.setBackgroundColor(Color.BLACK);
        WebSettings settings = web.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setMediaPlaybackRequiresUserGesture(false);
        settings.setCacheMode(WebSettings.LOAD_NO_CACHE);
        web.setWebViewClient(new WebViewClient() {
            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) offline();
            }

            @Override
            public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse response) {
                if (request.isForMainFrame()) offline();
            }
        });
        setContentView(web);

        url = urlOf(getIntent());
        web.loadUrl(url);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        url = urlOf(intent);
        handler.removeCallbacks(reload);
        web.loadUrl(url);
    }

    private static String urlOf(Intent intent) {
        String data = intent.getDataString();
        return data != null ? data : DEFAULT_URL;
    }

    private void offline() {
        web.loadDataWithBaseURL(null, OFFLINE_PAGE, "text/html", "utf-8", null);
        handler.removeCallbacks(reload);
        handler.postDelayed(reload, RETRY_MS);
    }

    @Override
    protected void onResume() {
        super.onResume();
        web.onResume();
        hideSystemUi();
    }

    @Override
    protected void onPause() {
        web.onPause();
        super.onPause();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideSystemUi();
    }

    private void hideSystemUi() {
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                | View.SYSTEM_UI_FLAG_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
    }

    /** A panel: Back doesn't close it (Home still leaves). */
    @Override
    public void onBackPressed() {}

    @Override
    protected void onDestroy() {
        handler.removeCallbacks(reload);
        web.destroy();
        super.onDestroy();
    }
}
