
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class GraduateConcurrencyTest {
  static Future<String> runG01({
    required String roundId,
    required int score,
  }) async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return 'ERROR: Sign in first';
    }

    if (score < 0 || score > 5) {
      return 'ERROR: Score must be between 0 and 5';
    }

    final reference = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('attempts')
        .doc(roundId);

    try {
      await FirebaseFirestore.instance.runTransaction((transaction) async {
        final snapshot = await transaction.get(reference);

        if (!snapshot.exists) {
          transaction.set(reference, {
            'schemaVersion': 1,
            'variant': 'B',
            'categoryId': 17,
            'questionCount': 5,
            'correctCount': score,
            'submittedAt': FieldValue.serverTimestamp(),
          });
        }
      });

      final saved = await reference.get(
        const GetOptions(source: Source.server),
      );

      if (!saved.exists || saved.metadata.hasPendingWrites) {
        return 'INCONCLUSIVE: Server verification failed';
      }

      final savedScore = saved.data()?['correctCount'];

      return savedScore == score
          ? 'Cloud verified: score $savedScore'
          : 'Collision detected: stored score $savedScore, '
              'attempted score $score';
    } on FirebaseException catch (e) {
      return 'Firebase error: ${e.code}';
    }
  }
}
