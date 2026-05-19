import 'package:flutter/material.dart';
import 'package:music_player/LoginPage.dart';
import 'package:music_player/user_session.dart';
//import 'package:music_player/MainHomePage.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UserSession().loadSavedCookies(); // restore cookies before app loads
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const Loginpage(),
    );
  }
}
