import 'package:flutter/material.dart';
import 'utils/constants.dart';
import 'pages/home_page.dart';

class SmartEyeApp extends StatelessWidget {
  const SmartEyeApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: AppConstants.primaryColor,
        scaffoldBackgroundColor: AppConstants.bgColor,
        appBarTheme: const AppBarTheme(centerTitle: true, elevation: 0, scrolledUnderElevation: 1),
        cardTheme: CardThemeData(elevation: 1, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMd)), surfaceTintColor: Colors.transparent),
        inputDecorationTheme: InputDecorationTheme(border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSm)), contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12), isDense: true),
        elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSm)), padding: const EdgeInsets.symmetric(vertical: 14), textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(type: BottomNavigationBarType.fixed, selectedItemColor: AppConstants.primaryColor, unselectedItemColor: AppConstants.textSecondary),
      ),
      home: const HomePage(),
    );
  }
}
