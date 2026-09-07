import 'package:flutter/material.dart';
import 'home_screen.dart';

void main() {
  runApp(const LaneSwitchApp());
}

class LaneSwitchApp extends StatelessWidget {
  const LaneSwitchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lane Switch System',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}
