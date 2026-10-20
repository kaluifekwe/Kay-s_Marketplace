import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/services/supabase_service.dart';
import 'core/services/escrow_service.dart';
import 'core/services/notification_service.dart';
import 'core/services/error_reporter.dart';
import 'bloc_exports.dart';
import 'theme/app_theme.dart';
import 'screens/splash/splash_screen.dart';
import 'screens/auth/welcome_screen.dart';
import 'screens/auth/login_screen.dart';

@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(message) async {
  await Firebase.initializeApp();
}

void main() {
  // Run inside a guarded zone so ANY uncaught async error is caught and logged
  // (best-effort, remotely) instead of crashing or vanishing silently.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Only what the FIRST FRAME genuinely needs is awaited here. Everything
    // before runApp holds the launch screen on the user's screen, so each
    // await is time the app looks like it has not started. Supabase is
    // unavoidable: the splash decides where to send the user from the restored
    // session, so it has to exist before anything renders. dotenv is a local
    // file read that Supabase depends on.
    await dotenv.load(fileName: '.env');

    await Supabase.initialize(
      url: dotenv.env['SUPABASE_URL']!,
      anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
    );

    await SupabaseService.init();

    // Friendly UI for render errors + remote logging of uncaught errors.
    // Version is read from pubspec by hand; it had been left at 1.0.4+5 while
    // the app shipped 1.0.8, so every reported error named the wrong build.
    ErrorReporter.install(appVersion: '1.0.8+13');

    final escrow = EscrowService();

    runApp(DispatchPHApp(escrow: escrow));

    // Everything below is off the critical path: it does not affect what the
    // user sees first, so it runs once the app is already on screen. Push
    // notifications a second late are unnoticeable; a second of blank screen
    // at launch is not.
    unawaited(() async {
      try {
        await Firebase.initializeApp();
        FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
      } catch (e, s) {
        // Push being unavailable must never stop the app from running.
        ErrorReporter.report(e, s, context: 'firebase_init');
      }
      await NotificationService.init();
    }());
  }, (error, stack) {
    ErrorReporter.report(error, stack, context: 'zone');
  });
}

class DispatchPHApp extends StatelessWidget {
  final EscrowService escrow;

  const DispatchPHApp({
    super.key,
    required this.escrow,
  });

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => AuthCubit()),
        BlocProvider(create: (_) => MarketplaceCubit()),
        BlocProvider(create: (_) => CartCubit()),
        BlocProvider(create: (_) => OrderCubit(escrow)),
        BlocProvider(create: (_) => ChatCubit(escrow)),
        BlocProvider(create: (_) => DisputeCubit()),
        BlocProvider(create: (_) => ReviewCubit()),
        BlocProvider(create: (_) => NotificationCubit()),
        BlocProvider(create: (_) => WalletCubit()),
      ],
      child: MaterialApp(
        title: "Kay's Market",
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        home: const SplashScreen(),
        routes: {
          '/welcome': (_) => const WelcomeScreen(),
          '/login': (_) => const LoginScreen(),
        },
      ),
    );
  }
}
