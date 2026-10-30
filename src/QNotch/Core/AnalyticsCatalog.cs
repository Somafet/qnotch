namespace QNotch.Core;

internal static class AnalyticsCatalog
{
    internal static readonly HashSet<string> Targets = ["about", "accent", "agents", "agents_show_cost", "agents_sound_done", "agents_sound_needs_you", "ai", "ai_claude", "ai_codex", "ai_refresh_minutes", "appearance", "automatic_install", "automatic_updates", "beta_updates", "capture", "card_visibility", "clipboard", "clipboard_history", "close_delay", "color_picker", "display", "features", "files", "game_always", "game_any_fullscreen", "game_auto_detect", "game_height", "game_mode", "game_never", "game_opacity", "game_position", "game_segment", "gamemode", "general", "github", "home", "hotkey", "hotkeys", "hover_delay", "hover_opens_segment", "login", "media", "menu_bar_icon", "notch_visibility", "notes", "notifications", "notifications_http_enabled", "notifications_http_port", "notifications_open_on_error", "notifications_quiet_during_calls", "notifications_retention_days", "notifications_sound", "notifications_toast_seconds", "pinned", "pomodoro", "profile_name", "profile_photo", "reduce_motion", "scheduled", "search", "sound", "sounds", "stats", "stats_battery", "stats_clock", "stats_cpu", "stats_gpu", "stats_memory", "stats_network", "tab_visibility", "telemetry", "terminal", "theme", "timer_open_when_done", "timer_sound", "weather", "weather_show_in_pill", "weather_units"];
    internal static bool Allows(string module, string action) => module switch
    {
        "agents" => action is "cli_hook" or "connect" or "disconnect" or "dismiss" or "show" or "stop_process",
        "ai" => action is "add_app" or "change" or "launch" or "refresh" or "remove_app" or "rename_account" or "scan" or "select_account" or "set_slot",
        "clipboard" => action is "change" or "clear" or "copy" or "pin" or "remove",
        "color_picker" => action is "copy" or "format" or "pick",
        "files" => action is "add" or "choose_files" or "clear" or "copy_path" or "export" or "open" or "quick_look" or "remove" or "reveal" or "reveal_received" or "select" or "select_all" or "select_none" or "share_close" or "share_copy_link" or "share_extend" or "share_open" or "share_start" or "share_stop",
        "github" => action is "cancel_connect" or "connect" or "disconnect" or "open_authorization" or "open_token_page" or "refresh" or "save" or "test_connection" or "use_token",
        "media" => action is "next" or "play_pause" or "previous" or "seek" or "select_session",
        "notes" => action is "save",
        "notifications" => action is "change" or "clear" or "cli_notify" or "copy_token" or "dismiss" or "invoke" or "mute_app" or "renew_token" or "reveal_token" or "send_test" or "toggle_mute",
        "onboarding" => action is "back" or "change_feature" or "change_login" or "finish" or "next" or "skip",
        "pomodoro" => action is "pause" or "reset" or "set_duration" or "start" or "toggle",
        "scheduled" => action is "pause" or "refresh" or "remove" or "resume" or "reveal" or "toggle_enabled",
        "search" => action is "run_result" or "submit",
        "settings" => action is "add_app" or "change" or "change_feature" or "change_presentation" or "change_shortcut" or "change_sound" or "choose" or "choose_photo" or "choose_sound" or "disconnect" or "exit" or "install" or "keep" or "notes" or "open_login_items" or "pick" or "play" or "preview_sound" or "remove_photo" or "reset_positions" or "reset_shortcut" or "reset_sound" or "select_section" or "setup_apply" or "setup_check" or "setup_export" or "tour" or "turn_off" or "x",
        "shell" => action is "change_card_visibility" or "check_updates" or "close_panel" or "game_mode" or "install_update" or "move_notch" or "open_panel" or "open_release_notes" or "open_settings" or "quit" or "reorder_cards" or "reorder_tabs" or "resize_card" or "restart" or "select_tab" or "toggle_edit" or "toggle_pin",
        "shortcuts" => action is "gamemode" or "toggle",
        "terminal" => action is "copy" or "paste" or "restart" or "submit",
        "volume" => action is "set_volume" or "toggle_mute",
        "weather" => action is "change" or "open_forecast" or "refresh" or "search" or "select_place",
        _ => false,
    };
}
