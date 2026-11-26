/// Maprisma Settings' (formerly Maprisma Manager) core: the catalog, status, git provenance and the routes.
library;

export 'package:maprisma_core_kit/desktop.dart' show pangoFamily;
export 'package:maprisma_core_kit/files.dart'
    show
        PrivateFolder,
        debugFailWriteAfter,
        debugShortWrite,
        debugWriteReturnsZero,
        makePrivateFolder,
        privateFilesMessageFormatter;
export 'package:maprisma_core_kit/screenshot.dart';

export 'src/about.dart';
export 'src/ai_update.dart';
export 'src/applications.dart';
export 'src/ai/ask_ai.dart' show AskError, helperStates, helpers, jailArgv, codexOff;
export 'src/ai/shared_helper.dart';
export 'src/bar.dart';
export 'src/bar_cosmic.dart';
export 'src/bar_hypr.dart';
export 'src/bar_kde.dart';
export 'src/bar_read.dart';
export 'src/bluetooth.dart';
export 'src/ron.dart';
export 'src/catalog.dart';
export 'src/cli.dart';
export 'src/context.dart';
export 'src/core.dart';
export 'src/desktop_look.dart';
export 'src/discovery.dart';
export 'src/displays.dart';
export 'src/hypr_config.dart';
export 'src/animations.dart';
export 'src/input.dart';
export 'src/theme_view.dart';
export 'src/git.dart';
export 'src/github.dart';
export 'src/icons.dart';
export 'src/sound.dart';
export 'src/sources.dart';
export 'src/jobs.dart';
export 'src/ownership.dart';
export 'src/native.dart';
export 'src/network.dart';
export 'src/notifications.dart';
export 'src/paths.dart';
export 'src/power.dart';
export 'src/procs.dart';
export 'src/protocol.dart';
export 'src/receipts.dart';
export 'src/removal.dart';
export 'src/run.dart';
export 'src/status.dart';
export 'src/system_apps.dart';
export 'src/time_lang.dart';
export 'src/sysproc.dart';
export 'src/translations.dart';
export 'src/voice.dart';
