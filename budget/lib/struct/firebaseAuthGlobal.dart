import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/accountAndBackup.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart' hide Transaction;

OAuthCredential? _credential;

Future<FirebaseFirestore?> firebaseGetDBInstanceAnonymous() async {
  try {
    await FirebaseAuth.instance.signInAnonymously();
    return FirebaseFirestore.instance;
  } catch (e) {
    print("There was an error with firebase login");
    print(e.toString());
    return null;
  }
}

// returns null if authentication unsuccessful
Future<FirebaseFirestore?> firebaseGetDBInstance() async {
  if (_credential != null) {
    try {
      await FirebaseAuth.instance.signInWithCredential(_credential!);
      updateSettings(
        "currentUserEmail",
        FirebaseAuth.instance.currentUser!.email,
        pagesNeedingRefresh: [],
        updateGlobalState: false,
      );
      return FirebaseFirestore.instance;
    } catch (e) {
      print("There was an error with firebase login");
      print(e.toString());
      print("will retry with a new credential");
      _credential = null;
      googleUser = null;
      return await firebaseGetDBInstance();
    }
  } else {
    try {
      if (googleUser == null) {
        await signInGoogle(silentSignIn: true);
      }
      // GoogleSignInAccount? googleUser = googleUser;

      // google_sign_in v7+: `authentication` is synchronous and only exposes
      // the idToken. The access token (if needed) is obtained from the
      // authorization client. idToken alone is sufficient for the Firebase
      // GoogleAuthProvider credential.
      final GoogleSignInAuthentication? googleAuth = googleUser?.authentication;

      String? accessToken;
      try {
        final authorization = await googleUser?.authorizationClient
            .authorizationForScopes(googleGrantedScopes);
        accessToken = authorization?.accessToken;
      } catch (e) {
        print("Could not obtain Google access token: ${e.toString()}");
      }

      _credential = GoogleAuthProvider.credential(
        accessToken: accessToken,
        idToken: googleAuth?.idToken,
      );

      await FirebaseAuth.instance.signInWithCredential(_credential!);
      updateSettings(
          "currentUserEmail", FirebaseAuth.instance.currentUser!.email,
          updateGlobalState: true);
      return FirebaseFirestore.instance;
    } catch (e) {
      print("There was an error with firebase login and possibly google");
      print(e.toString());
      return null;
    }
  }
}
