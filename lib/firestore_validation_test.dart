
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class FirestoreValidationTest {
  static Future<String> runTests() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return 'ERROR: Sign in first';
    }

    final attempts = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('attempts');

    final results = <String>[];

    // T11-A: Invalid score (6 out of 5)
    try {
      await attempts.doc('t11-invalid-score').set({
        'schemaVersion': 1,
        'variant': 'B',
        'categoryId': 17,
        'questionCount': 5,
        'correctCount': 6,
        'submittedAt': FieldValue.serverTimestamp(),
      });

      results.add('FAIL: Invalid score accepted');
    } on FirebaseException catch (e) {
      results.add(e.code == 'permission-denied'
          ? 'PASS: Invalid score denied'
          : 'INCONCLUSIVE: Invalid score ${e.code}');
    }

    // T11-B: Unauthorized extra field
    try {
      await attempts.doc('t11-extra-field').set({
        'schemaVersion': 1,
        'variant': 'B',
        'categoryId': 17,
        'questionCount': 5,
        'correctCount': 3,
        'submittedAt': FieldValue.serverTimestamp(),
        'extraField': 'not allowed',
      });

      results.add('FAIL: Extra field accepted');
    } on FirebaseException catch (e) {
      results.add(e.code == 'permission-denied'
          ? 'PASS: Extra field denied'
          : 'INCONCLUSIVE: Extra field ${e.code}');
    }

    // T11-C: Create a valid record, then attempt to modify it.
    final reference = attempts.doc(
      't11-immutable-${DateTime.now().microsecondsSinceEpoch}',
    );

    try {
      await reference.set({
        'schemaVersion': 1,
        'variant': 'B',
        'categoryId': 17,
        'questionCount': 5,
        'correctCount': 2,
        'submittedAt': FieldValue.serverTimestamp(),
      });

      // Confirm the valid record exists on the server.
      final before = await reference.get(
        const GetOptions(source: Source.server),
      );

      if (!before.exists || before.data()?['correctCount'] != 2) {
        results.add('INCONCLUSIVE: Valid setup not verified');
      } else {
        try {
          await reference.update({'correctCount': 5});
          results.add('FAIL: Existing record updated');
        } on FirebaseException catch (e) {
          if (e.code != 'permission-denied') {
            results.add('INCONCLUSIVE: Update ${e.code}');
          } else {
            final after = await reference.get(
              const GetOptions(source: Source.server),
            );

            if (after.data()?['correctCount'] == 2) {
              results.add('PASS: Existing record immutable');
            } else {
              results.add('FAIL: Original record changed');
            }
          }
        }
      }
    } on FirebaseException catch (e) {
      results.add('INCONCLUSIVE: Setup ${e.code}');
    }

    return results.join('\n');
  }
}
