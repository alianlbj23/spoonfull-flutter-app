import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'core/theme/app_theme.dart';
import 'services/app_services.dart';
import 'state/device_state.dart';
import 'state/hardware_state.dart';
import 'state/record_state.dart';
import 'state/sync_state.dart';
import 'ui/screens/welcome_screen.dart';
import 'ui/widgets/design_canvas.dart';

class SpoonfullApp extends StatelessWidget {
  const SpoonfullApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppServices>.value(value: services),
        ChangeNotifierProvider(
          create: (_) => DeviceState(services)..initialize(),
        ),
        ChangeNotifierProvider(create: (_) => SyncState(services)),
        ChangeNotifierProvider(create: (_) => RecordState(services)..loadAll()),
        ChangeNotifierProvider(create: (_) => HardwareState(services)),
      ],
      child: MaterialApp(
        title: 'Spoonfull',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        locale: const Locale('zh', 'TW'),
        supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => DesignCanvas(child: child!),
        home: const WelcomeScreen(),
      ),
    );
  }
}
