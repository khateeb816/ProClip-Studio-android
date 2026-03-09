import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Auth state stream
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // Get current user
  User? get currentUser => _auth.currentUser;

  // Stream of user data from Firestore
  Stream<DocumentSnapshot<Map<String, dynamic>>> userStream([String? userId]) {
    final uid = userId ?? currentUser?.uid;
    if (uid == null) {
      return const Stream.empty();
    }
    return _firestore.collection('users').doc(uid).snapshots();
  }

  // Register with email and password
  Future<UserCredential?> registerWithEmailPassword({
    required String email,
    required String password,
    required String displayName,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Update display name
      await credential.user?.updateDisplayName(displayName);

      // Create user document in Firestore
      await _createUserDocument(credential.user!);

      return credential;
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    } catch (e) {
      throw 'Registration failed: $e';
    }
  }

  // Sign in with email and password
  Future<UserCredential?> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      
      if (credential.user != null) {
        await _verifyPremiumDevice(credential.user!);
      }
      
      return credential;
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    } catch (e) {
      if (e.toString().contains('This Premium account is bound to another device')) rethrow;
      throw 'Sign in failed: $e';
    }
  }

  // Sign in with Google
  Future<UserCredential?> signInWithGoogle() async {
    try {
      // Trigger the authentication flow
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();

      if (googleUser == null) {
        return null; // User cancelled
      }

      // Obtain the auth details from the request
      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;

      // Create a new credential
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      // Sign in to Firebase with the Google credential
      final userCredential = await _auth.signInWithCredential(credential);

      // Create user document if new user
      if (userCredential.additionalUserInfo?.isNewUser ?? false) {
        await _createUserDocument(userCredential.user!);
      }

      if (userCredential.user != null) {
        await _verifyPremiumDevice(userCredential.user!);
      }

      return userCredential;
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    } catch (e) {
      if (e.toString().contains('This Premium account is bound to another device')) rethrow;
      throw 'Google sign in failed: $e';
    }
  }

  // Sign out
  Future<void> signOut() async {
    try {
      await Future.wait([
        _auth.signOut(),
        _googleSignIn.signOut(),
      ]);
    } catch (e) {
      throw 'Sign out failed: $e';
    }
  }

  // Create user document in Firestore
  Future<void> _createUserDocument(User user) async {
    try {
      await _firestore.collection('users').doc(user.uid).set({
        'uid': user.uid,
        'email': user.email,
        'displayName': user.displayName ?? 'User',
        'photoURL': user.photoURL,
        'role': 'user', // Default role
        'subscriptionStatus': 'free', // Default subscription
        'subscriptionPlan': null, // No plan for free users
        'subscriptionExpiry': null, // No expiry for free users
        'isActive': true, // Account is active by default
        'boundDeviceId': null, // For Premium Device Integrity
        'clipsExported': 0, // Number of clips exported
        'clipsUploaded': 0, // Number of clips shared/uploaded
        'createdAt': FieldValue.serverTimestamp(),
        'lastLogin': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error creating user document: $e');
    }
  }

  // Handle Firebase Auth exceptions
  String _handleAuthException(FirebaseAuthException e) {
    switch (e.code) {
      case 'weak-password':
        return 'The password is too weak.';
      case 'email-already-in-use':
        return 'An account already exists for this email.';
      case 'invalid-email':
        return 'The email address is invalid.';
      case 'user-not-found':
        return 'No user found with this email.';
      case 'wrong-password':
        return 'Incorrect password.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'too-many-requests':
        return 'Too many attempts. Please try again later.';
      case 'operation-not-allowed':
        return 'This sign-in method is not enabled.';
      default:
        return 'Authentication error: ${e.message}';
    }
  }

  // Reset password
  Future<void> resetPassword(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    } catch (e) {
      throw 'Password reset failed: $e';
    }
  }

  // Get user role from Firestore
  Future<String?> getUserRole() async {
    try {
      final uid = currentUser?.uid;
      if (uid == null) return null;

      final doc = await _firestore.collection('users').doc(uid).get();
      return doc.data()?['role'] as String?;
    } catch (e) {
      print('Error getting user role: $e');
      return null;
    }
  }

  // Check if current user is admin
  Future<bool> isAdmin() async {
    final role = await getUserRole();
    return role == 'admin';
  }

  // Get complete user data from Firestore
  Future<Map<String, dynamic>?> getUserData([String? userId]) async {
    try {
      final uid = userId ?? currentUser?.uid;
      if (uid == null) return null;

      final doc = await _firestore.collection('users').doc(uid).get();
      return doc.data();
    } catch (e) {
      print('Error getting user data: $e');
      return null;
    }
  }

  // Increment clip statistics
  Future<void> incrementClipStats({bool isExport = false, bool isUpload = false}) async {
    try {
      final uid = currentUser?.uid;
      if (uid == null) return;

      final updates = <String, dynamic>{};
      if (isExport) updates['clipsExported'] = FieldValue.increment(1);
      if (isUpload) updates['clipsUploaded'] = FieldValue.increment(1);

      if (updates.isNotEmpty) {
        await _firestore.collection('users').doc(uid).update(updates);
      }
      
      // Update global device export count for Free users
      if (isExport) {
         final doc = await _firestore.collection('users').doc(uid).get();
         if (doc.exists && doc.data()?['subscriptionStatus'] == 'free') {
             final deviceId = await getDeviceId();
             await _firestore.collection('devices').doc(deviceId).set({
                 'freeClipsExported': FieldValue.increment(1),
                 'lastUpdated': FieldValue.serverTimestamp(),
             }, SetOptions(merge: true));
         }
      }
    } catch (e) {
      print('Error incrementing clip stats: $e');
    }
  }

  // --- Device Integrity ---
  Future<String> getDeviceId() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        return iosInfo.identifierForVendor ?? await _getPrefsDeviceId();
      } else if (Platform.isAndroid) {
        // androidId is restricted in newer plugins, so generating a persistent UUID or using ID
        final androidInfo = await deviceInfo.androidInfo;
        return androidInfo.id; // Usually a build ID or android ID based on OS
      }
    } catch (e) {
       return await _getPrefsDeviceId();
    }
    return await _getPrefsDeviceId();
  }

  Future<String> _getPrefsDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString('persistent_device_id');
    if (deviceId == null) {
      deviceId = const Uuid().v4();
      await prefs.setString('persistent_device_id', deviceId);
    }
    return deviceId;
  }

  Future<void> _verifyPremiumDevice(User user) async {
    final doc = await _firestore.collection('users').doc(user.uid).get();
    final data = doc.data();
    if (data == null) return;
    
    final status = data['subscriptionStatus'] as String? ?? 'free';
    if (status != 'free') {
       final boundDevice = data['boundDeviceId'] as String?;
       final currentDevice = await getDeviceId();
       
       if (boundDevice == null || boundDevice.isEmpty) {
           // Bind the device
           await _firestore.collection('users').doc(user.uid).update({
              'boundDeviceId': currentDevice
           });
       } else if (boundDevice != currentDevice) {
           await signOut();
           throw 'This Premium account is bound to another device. Please contact Admin to remove the old device.';
       }
    }
  }
}
