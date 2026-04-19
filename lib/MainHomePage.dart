import 'package:flutter/material.dart';
import 'package:music_player/HomePage.dart';
import 'package:music_player/LoginPage.dart';
import 'package:music_player/user_session.dart';
//import 'package:google_sign_in/google_sign_in.dart';

class Mainhomepage extends StatefulWidget {
  const Mainhomepage({super.key});

  @override
  State<Mainhomepage> createState() => _MainhomepageState();
}

class _MainhomepageState extends State<Mainhomepage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _appbar(),
      body: const Homepage(),
      drawer: _Drawer(),
      bottomNavigationBar: _BottomNav(),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!UserSession().isLoggedIn) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const Loginpage()),
        );
      }
    });
  }

  AppBar _appbar() {
    return AppBar(
      backgroundColor: Colors.black,
      leading: Builder(
        builder: (context) => IconButton(
          onPressed: () => Scaffold.of(context).openDrawer(),
          icon: Icon(Icons.menu, color: Colors.white),
        ),
      ),
    );
  }

  Widget _Drawer() {
    return Drawer(
      backgroundColor: const Color.fromARGB(255, 22, 22, 22),
      child: ListView(
        children: [
          UserAccountsDrawerHeader(
            decoration: BoxDecoration(color: Colors.grey.shade900),

            accountName: Text(
              UserSession().displayName,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            accountEmail: Text(
              UserSession().email,
              style: const TextStyle(color: Colors.grey),
            ),

            currentAccountPicture: Builder(
              builder: (context) {
                final String? photoUrl = UserSession().photoUrl;
                return CircleAvatar(
                  backgroundColor: Colors.grey,
                  backgroundImage: photoUrl != null
                      ? NetworkImage(photoUrl)
                      : null,
                  child: photoUrl == null
                      ? Text(
                          UserSession().displayName.isNotEmpty
                              ? UserSession().displayName[0].toUpperCase()
                              : '?',
                          style: const TextStyle(
                            fontSize: 30,
                            color: Colors.white,
                          ),
                        )
                      : null,
                );
              },
            ),
          ),
          ListTile(
            leading: Icon(Icons.person_2_outlined, color: Colors.grey),
            title: Text("Account", style: TextStyle(color: Colors.grey)),
            onTap: () {},
          ),
          ListTile(
            leading: Icon(Icons.settings, color: Colors.grey),
            title: Text("Setting", style: TextStyle(color: Colors.grey)),
            onTap: () {},
          ),
          ListTile(
            leading: Icon(Icons.logout_outlined, color: Colors.redAccent),
            title: const Text(
              "Log Out",
              style: TextStyle(color: Colors.redAccent),
            ),
            onTap: () async {
              await UserSession().googleSignIn?.signOut();
              UserSession().clear();
              if (mounted) {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (context) => const Loginpage()),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _BottomNav() {
    return BottomNavigationBar(
      selectedLabelStyle: TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.bold,
      ),
      unselectedLabelStyle: TextStyle(
        color: Colors.grey,
        fontWeight: FontWeight.normal,
      ),
      selectedItemColor: Colors.white,
      unselectedItemColor: Colors.grey,
      backgroundColor: Colors.grey.shade900,
      type: BottomNavigationBarType.fixed,
      items: const [
        BottomNavigationBarItem(icon: Icon(Icons.home_filled), label: 'Home'),
        BottomNavigationBarItem(
          icon: Icon(Icons.library_music_outlined),
          label: 'Libary',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.download_rounded),
          label: 'Download',
        ),
      ],
    );
  }
}
