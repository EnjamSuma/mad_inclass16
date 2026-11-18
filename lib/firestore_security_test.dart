
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class FirestoreSecurityTest {
  static Future<String> testUserAccess({
    required String userAUid,
    required String userARoundId,
  }) async {
    final userB = FirebaseAuth.instance.currentUser;

    if (userB == null) {
      return 'Test failed: no authenticated user';
    }

    if (userB.uid == userAUid) {
      return 'Test invalid: sign in as User B';
    }

    final reference = FirebaseFirestore.instance
        .collection('users')
        .doc(userAUid)
        .collection('attempts')
        .doc(userARoundId);

    String readResult;
    String writeResult;

    try {
      await reference.get(
        const GetOptions(source: Source.server),
      );

      readResult = 'FAIL: User B read User A record';
    } on FirebaseException catch (e) {
      readResult = e.code == 'permission-denied'
          ? 'PASS: Cross-user read denied'
          : 'INCONCLUSIVE: Read error ${e.code}';
    }

    try {
      await reference.set({
        'schemaVersion': 1,
        'variant': 'B',
        'categoryId': 17,
        'questionCount': 5,
        'correctCount': 2,
        'submittedAt': FieldValue.serverTimestamp(),
      });

      writeResult = 'FAIL: User B wrote to User A path';
    } on FirebaseException catch (e) {
      writeResult = e.code == 'permission-denied'
          ? 'PASS: Cross-user write denied'
          : 'INCONCLUSIVE: Write error ${e.code}';
    }

    return '$readResult\n$writeResult';
  }
}
