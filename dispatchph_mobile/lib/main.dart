import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/services/supabase_service.dart';
import 'core/services/escrow_service.dart';
import 'core/services/notification_service.dart';
import 'core/services/fcm_service.dart';
import 'bloc_exports.dart';
import 'theme/app_theme.dart';
import 'screens/splash/splash_screen.dart';
import 'screens/auth/welcome_screen.dart';
import 'screens/auth/login_screen.dart';

@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(message) async {
  await Firebase.initializeApp();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();

  await dotenv.load(fileName: '.env');

  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );

  await SupabaseService.init();
  await NotificationService.init();

  FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);

  final escrow = EscrowService();

  runApp(DispatchPHApp(escrow: escrow));
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
        title: "Kays Market",
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
