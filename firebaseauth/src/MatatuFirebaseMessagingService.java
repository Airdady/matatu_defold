package com.defold.android.firebaseauth;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Typeface;
import android.media.AudioAttributes;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Build;
import android.text.Html;
import android.text.SpannableStringBuilder;
import android.text.Spanned;
import android.text.style.StyleSpan;
import android.util.Log;

import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;

import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

import java.util.Map;
import java.util.Random;

/**
 * High-Priority, Rich Interactive Firebase Messaging Service.
 * Formats notification layouts, heads-up banners, vibration patterns,
 * and adds actionable Accept / Decline buttons (Notifee design style).
 */
public class MatatuFirebaseMessagingService extends FirebaseMessagingService {

    private static final String TAG = "MatatuFCM";

    public static final String CHANNEL_GAME_REQUESTS = "game_requests";
    public static final String CHANNEL_DAILY_REWARDS = "daily_rewards";
    public static final String CHANNEL_TOURNAMENTS = "prizes_and_tournaments";
    public static final String CHANNEL_SAVINGS = "account_and_savings";
    public static final String CHANNEL_GENERAL = "general_channel";

    private static final int BRAND_COLOR = 0xFFFF8C00; // Matatu Amber Gold

    @Override
    public void onNewToken(String token) {
        super.onNewToken(token);
        Log.i(TAG, "New FCM Token received: " + token);
        try {
            FirebaseAuthDefold.onFcmTokenReceived(token);
        } catch (Throwable t) {
            Log.w(TAG, "Could not relay token to native layer: " + t.getMessage());
        }
    }

    @Override
    public void onMessageReceived(RemoteMessage remoteMessage) {
        super.onMessageReceived(remoteMessage);
        Log.i(TAG, "FCM Message received from: " + remoteMessage.getFrom());

        try {
            Map<String, String> data = remoteMessage.getData();
            RemoteMessage.Notification notif = remoteMessage.getNotification();

            String type = data.containsKey("type") ? data.get("type") : "GENERAL";
            String title = notif != null && notif.getTitle() != null
                    ? notif.getTitle()
                    : (data.containsKey("title") ? data.get("title") : "Matatu");
            String body = notif != null && notif.getBody() != null
                    ? notif.getBody()
                    : (data.containsKey("body") ? data.get("body") : "");

            displayRichNotification(this, type, title, body, data);
        } catch (Exception e) {
            Log.e(TAG, "Error displaying incoming push notification: " + e.getMessage(), e);
        }
    }

    /**
     * Renders the small set of HTML tags Android notifications support.
     *
     * The server wraps a player's name in <b> so it stands out from the sentence
     * around it, which is the one word in an invite that actually identifies
     * who is asking. Passed through as a plain String those tags render
     * LITERALLY — the player reads "&lt;b&gt;Mubarak&lt;/b&gt; challenged you" —
     * so parsing here is not decoration, it is what stops the markup leaking
     * into the copy.
     *
     * Falls back to the raw string on any failure. A name that is not bold is a
     * cosmetic loss; a notification that fails to build is a missed invite.
     */
    private static CharSequence richText(String s) {
        if (s == null) return "";
        // Nothing to parse. Skips the work for the majority of notifications and
        // avoids Html.fromHtml's entity handling touching copy that never asked
        // for it — an ampersand in a username should stay an ampersand.
        if (s.indexOf('<') < 0) return s;

        CharSequence out = s;
        try {
            out = Build.VERSION.SDK_INT >= Build.VERSION_CODES.N
                    ? Html.fromHtml(s, Html.FROM_HTML_MODE_LEGACY)
                    : Html.fromHtml(s);
        } catch (Exception e) {
            Log.w(TAG, "richText: HTML parse failed: " + e.getMessage());
        }

        // LAST RESORT. If anything at all went wrong — a parser that left the
        // tags in place, an OEM with its own idea of fromHtml, a server sending
        // markup this build does not know — the player must NEVER read
        // "<b>Mubarak</b>". Losing the bold is invisible; showing the tags is
        // the bug being reported.
        if (out.toString().contains("<b>") || out.toString().contains("</b>")) {
            Log.w(TAG, "richText: tags survived parsing, stripping them");
            return s.replaceAll("<[^>]*>", "");
        }
        return out;
    }

    /**
     * Bold one substring of an otherwise plain sentence.
     *
     * THE REASON THIS EXISTS RATHER THAN MORE HTML
     *
     * Emboldening by shipping "<b>name</b>" and parsing it on arrival has one
     * failure mode, and it is the worst one available: when the parsing does not
     * happen, the player reads the markup. That is what was reported.
     *
     * A span cannot fail that way. The server sends the sentence as PLAIN TEXT
     * plus the exact substring to embolden, and the weight is applied here. There
     * are no tags to leak, nothing to escape, and no dependence on Html.fromHtml
     * behaving the same on every OEM — the worst case is a name that is not bold.
     *
     * Falls back to the plain string whenever the substring is absent, which also
     * makes it safe against an older server that still sends markup: richText
     * above has already dealt with that by then.
     */
    private static CharSequence applyBold(CharSequence text, String boldText) {
        if (text == null) return "";
        if (boldText == null || boldText.trim().isEmpty()) return text;

        String plain = text.toString();
        int at = plain.indexOf(boldText);
        if (at < 0) return text;

        try {
            SpannableStringBuilder sb = new SpannableStringBuilder(plain);
            sb.setSpan(new StyleSpan(Typeface.BOLD), at, at + boldText.length(),
                    Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            return sb;
        } catch (Exception e) {
            Log.w(TAG, "applyBold failed, showing plain: " + e.getMessage());
            return text;
        }
    }

    /**
     * Constructs and displays a rich heads-up notification with action buttons.
     */
    public static void displayRichNotification(Context context, String type, String title, String body, Map<String, String> data) {
        ensureNotificationChannels(context);

        String channelId = resolveChannelId(type);
        int notificationId = new Random().nextInt(100000) + 1000;

        Intent launchIntent = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        if (launchIntent == null) {
            launchIntent = new Intent(Intent.ACTION_MAIN);
            launchIntent.setPackage(context.getPackageName());
        }
        launchIntent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        launchIntent.putExtra("push_type", type);
        launchIntent.putExtra("notification_id", notificationId);

        // Populate extra data from payload
        if (data != null) {
            for (Map.Entry<String, String> entry : data.entrySet()) {
                launchIntent.putExtra(entry.getKey(), entry.getValue());
            }
        }

        int pendingIntentFlags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            pendingIntentFlags |= PendingIntent.FLAG_IMMUTABLE;
        }

        PendingIntent contentPendingIntent = PendingIntent.getActivity(
                context,
                notificationId,
                launchIntent,
                pendingIntentFlags
        );

        // Resolve notification icon
        int smallIcon = context.getResources().getIdentifier("app_logo", "drawable", context.getPackageName());
        if (smallIcon == 0) {
            smallIcon = context.getResources().getIdentifier("ic_launcher", "mipmap", context.getPackageName());
        }
        if (smallIcon == 0) {
            smallIcon = android.R.drawable.ic_dialog_info;
        }

        Uri defaultSoundUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION);
        long[] vibrationPattern = new long[]{0, 450, 200, 450};

        // Two passes, in this order, and both are defensive rather than
        // decorative.
        //
        //   richText   handles a body that still arrives as markup — an older
        //              server, or any path this build does not know about — and
        //              strips the tags outright if parsing leaves them behind.
        //              Whatever happens, no player reads "<b>Mubarak</b>".
        //   applyBold  the way it is meant to work now: a plain sentence plus
        //              the substring to embolden, weighted with a span. Nothing
        //              to leak and nothing to escape.
        //
        // Together they mean the name is bold when everything lines up, plain
        // when it does not, and never raw markup either way.
        String boldText = data != null ? data.get("boldText") : null;
        CharSequence styledBody = applyBold(richText(body), boldText);

        NotificationCompat.Builder builder = new NotificationCompat.Builder(context, channelId)
                .setSmallIcon(smallIcon)
                .setContentTitle(richText(title))
                .setContentText(styledBody)
                .setStyle(new NotificationCompat.BigTextStyle()
                        .bigText(styledBody)
                        .setBigContentTitle(richText(title)))
                .setColor(BRAND_COLOR)
                .setContentIntent(contentPendingIntent)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_MAX) // Maximum importance (Heads-Up)
                .setDefaults(NotificationCompat.DEFAULT_ALL)
                .setVibrate(vibrationPattern)
                .setLights(BRAND_COLOR, 1000, 500)
                .setSound(defaultSoundUri);

        // Add contextual interactive buttons according to notification type
        if ("GAME_REQUEST".equalsIgnoreCase(type)) {
            builder.setCategory(NotificationCompat.CATEGORY_CALL); // High priority call/invite heads-up

            // 1. ACCEPT ACTION (Launches game directly into match)
            Intent acceptIntent = (Intent) launchIntent.clone();
            acceptIntent.setAction("com.matatu.champ.ACTION_ACCEPT_GAME");
            acceptIntent.putExtra("push_action", "accept");
            // The requestId travels WITH the action. Without it the app knows
            // the player pressed Accept but not what they accepted, which is a
            // launch into the lobby and an invite that quietly expires.
            if (data != null && data.containsKey("requestId")) {
                acceptIntent.putExtra("push_request_id", data.get("requestId"));
            }
            PendingIntent acceptPendingIntent = PendingIntent.getActivity(
                    context,
                    notificationId + 1,
                    acceptIntent,
                    pendingIntentFlags
            );
            builder.addAction(android.R.drawable.ic_media_play, "Accept", acceptPendingIntent);

            // 2. DECLINE ACTION (Dismisses notification cleanly via receiver)
            Intent declineIntent = new Intent(context, NotificationActionReceiver.class);
            declineIntent.setAction(NotificationActionReceiver.ACTION_DECLINE);
            declineIntent.putExtra(NotificationActionReceiver.EXTRA_NOTIFICATION_ID, notificationId);
            if (data != null && data.containsKey("requestId")) {
                declineIntent.putExtra(NotificationActionReceiver.EXTRA_REQUEST_ID, data.get("requestId"));
            }
            PendingIntent declinePendingIntent = PendingIntent.getBroadcast(
                    context,
                    notificationId + 2,
                    declineIntent,
                    pendingIntentFlags
            );
            builder.addAction(android.R.drawable.ic_menu_close_clear_cancel, "Decline", declinePendingIntent);

        } else if ("DAILY_BONUS_REMINDER".equalsIgnoreCase(type)) {
            builder.setCategory(NotificationCompat.CATEGORY_PROMO);

            Intent claimIntent = (Intent) launchIntent.clone();
            claimIntent.putExtra("push_action", "claim_daily_bonus");
            PendingIntent claimPendingIntent = PendingIntent.getActivity(
                    context,
                    notificationId + 1,
                    claimIntent,
                    pendingIntentFlags
            );
            builder.addAction(android.R.drawable.ic_input_add, "Claim Bonus", claimPendingIntent);

        } else if ("TOURNAMENT_OPEN".equalsIgnoreCase(type) || "TOURNAMENT_CLOSING_SOON".equalsIgnoreCase(type)) {
            builder.setCategory(NotificationCompat.CATEGORY_EVENT);

            Intent tourneyIntent = (Intent) launchIntent.clone();
            tourneyIntent.putExtra("push_action", "open_tournament");
            PendingIntent tourneyPendingIntent = PendingIntent.getActivity(
                    context,
                    notificationId + 1,
                    tourneyIntent,
                    pendingIntentFlags
            );
            builder.addAction(android.R.drawable.ic_dialog_map, "Join Battle", tourneyPendingIntent);

        } else if ("SAVINGS_MILESTONE".equalsIgnoreCase(type)) {
            builder.setCategory(NotificationCompat.CATEGORY_STATUS);

            Intent savingsIntent = (Intent) launchIntent.clone();
            savingsIntent.putExtra("push_action", "open_savings");
            PendingIntent savingsPendingIntent = PendingIntent.getActivity(
                    context,
                    notificationId + 1,
                    savingsIntent,
                    pendingIntentFlags
            );
            builder.addAction(android.R.drawable.ic_menu_view, "View Vault", savingsPendingIntent);

        } else if ("PRIZE_CONGRATULATIONS".equalsIgnoreCase(type)) {
            builder.setCategory(NotificationCompat.CATEGORY_STATUS);

            Intent prizeIntent = (Intent) launchIntent.clone();
            prizeIntent.putExtra("push_action", "open_standings");
            PendingIntent prizePendingIntent = PendingIntent.getActivity(
                    context,
                    notificationId + 1,
                    prizeIntent,
                    pendingIntentFlags
            );
            builder.addAction(android.R.drawable.ic_menu_agenda, "View Prize", prizePendingIntent);
        }

        NotificationManagerCompat notificationManager = NotificationManagerCompat.from(context);
        try {
            notificationManager.notify(notificationId, builder.build());
            Log.i(TAG, "Notification #" + notificationId + " (" + type + ") dispatched successfully");
        } catch (SecurityException se) {
            Log.w(TAG, "Notification permission not granted: " + se.getMessage());
        }
    }

    private static String resolveChannelId(String type) {
        if (type == null) return CHANNEL_GENERAL;
        switch (type.toUpperCase()) {
            case "GAME_REQUEST":
                return CHANNEL_GAME_REQUESTS;
            case "DAILY_BONUS_REMINDER":
                return CHANNEL_DAILY_REWARDS;
            case "TOURNAMENT_OPEN":
            case "TOURNAMENT_CLOSING_SOON":
            case "PRIZE_CONGRATULATIONS":
                return CHANNEL_TOURNAMENTS;
            case "SAVINGS_MILESTONE":
            case "BALANCE_UPDATE":
            case "TRANSACTION":
                return CHANNEL_SAVINGS;
            default:
                return CHANNEL_GENERAL;
        }
    }

    public static void ensureNotificationChannels(Context context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && context != null) {
            try {
                NotificationManager manager = context.getSystemService(NotificationManager.class);
                if (manager == null) return;

                AudioAttributes audioAttributes = new AudioAttributes.Builder()
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_COMMUNICATION_REQUEST)
                        .build();
                Uri soundUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION);
                long[] vibrationPattern = new long[]{0, 450, 200, 450};

                // 1. Game Requests Channel (MAX IMPORTANCE - Heads-up popover)
                NotificationChannel gameRequests = new NotificationChannel(
                        CHANNEL_GAME_REQUESTS,
                        "Game Challenges & Invites",
                        NotificationManager.IMPORTANCE_HIGH
                );
                gameRequests.setDescription("Live game requests, tournament invites and battle challenges");
                gameRequests.enableLights(true);
                gameRequests.setLightColor(BRAND_COLOR);
                gameRequests.enableVibration(true);
                gameRequests.setVibrationPattern(vibrationPattern);
                gameRequests.setSound(soundUri, audioAttributes);
                gameRequests.setBypassDnd(true);
                gameRequests.setShowBadge(true);
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    gameRequests.setAllowBubbles(true);
                }

                // 2. Daily Rewards Channel (HIGH IMPORTANCE)
                NotificationChannel dailyRewards = new NotificationChannel(
                        CHANNEL_DAILY_REWARDS,
                        "Daily Bonuses & Streaks",
                        NotificationManager.IMPORTANCE_HIGH
                );
                dailyRewards.setDescription("Daily streak reminders, login bonuses and free gifts");
                dailyRewards.enableLights(true);
                dailyRewards.setLightColor(BRAND_COLOR);
                dailyRewards.enableVibration(true);
                dailyRewards.setShowBadge(true);

                // 3. Tournaments & Prizes (HIGH IMPORTANCE)
                NotificationChannel tournaments = new NotificationChannel(
                        CHANNEL_TOURNAMENTS,
                        "Tournaments & Prize Standings",
                        NotificationManager.IMPORTANCE_HIGH
                );
                tournaments.setDescription("Tournament start alerts, season end payouts and winning announcements");
                tournaments.enableLights(true);
                tournaments.setLightColor(Color.YELLOW);
                tournaments.enableVibration(true);
                tournaments.setShowBadge(true);

                // 4. Account & Savings (HIGH IMPORTANCE)
                NotificationChannel savings = new NotificationChannel(
                        CHANNEL_SAVINGS,
                        "Account & Savings Updates",
                        NotificationManager.IMPORTANCE_HIGH
                );
                savings.setDescription("Savings vault milestones, deposits and balance updates");
                savings.enableLights(true);
                savings.setLightColor(Color.GREEN);
                savings.enableVibration(true);
                savings.setShowBadge(true);

                // 5. General Channel (HIGH IMPORTANCE)
                NotificationChannel general = new NotificationChannel(
                        CHANNEL_GENERAL,
                        "General Notifications",
                        NotificationManager.IMPORTANCE_HIGH
                );
                general.setDescription("General announcements and updates");
                general.enableLights(true);
                general.enableVibration(true);
                general.setShowBadge(true);

                manager.createNotificationChannel(gameRequests);
                manager.createNotificationChannel(dailyRewards);
                manager.createNotificationChannel(tournaments);
                manager.createNotificationChannel(savings);
                manager.createNotificationChannel(general);

                Log.i(TAG, "All rich notification channels successfully registered with MAXIMUM importance");
            } catch (Exception e) {
                Log.w(TAG, "Error registering notification channels: " + e.getMessage());
            }
        }
    }
}
