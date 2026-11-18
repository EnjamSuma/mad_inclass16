
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class PreviousAttemptScreen extends StatefulWidget {
  final User user;

  const PreviousAttemptScreen({
    super.key,
    required this.user,
  });

  @override
  State<PreviousAttemptScreen> createState() =>
      _PreviousAttemptScreenState();
}

class _PreviousAttemptScreenState
    extends State<PreviousAttemptScreen> {
  final roundIdController = TextEditingController();

  bool loading = false;
  String? error;
  Map<String, dynamic>? result;

  Future<void> retrieveAttempt() async {
    final roundId = roundIdController.text.trim();

    if (roundId.isEmpty || roundId.contains('/')) {
      setState(() {
        error = 'Enter a valid round ID.';
      });
      return;
    }

    if (loading) return;

    setState(() {
      loading = true;
      error = null;
      result = null;
    });

    try {
      final uid = widget.user.uid;

      if (FirebaseAuth.instance.currentUser?.uid != uid) {
        throw StateError('Authenticated user changed.');
      }

      final reference = FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('attempts')
          .doc(roundId);

      final snapshot = await reference.get(
        const GetOptions(source: Source.server),
      ).timeout(const Duration(seconds: 10));

      if (!mounted ||
          FirebaseAuth.instance.currentUser?.uid != uid) {
        return;
      }

      if (!snapshot.exists ||
          snapshot.metadata.isFromCache ||
          snapshot.metadata.hasPendingWrites) {
        throw StateError('No verified server record found.');
      }

      final data = snapshot.data();

      if (data == null ||
          data.length != 6 ||
          data['schemaVersion'] != 1 ||
          data['variant'] != 'B' ||
          data['categoryId'] != 17 ||
          data['questionCount'] != 5 ||
          data['correctCount'] is! int ||
          (data['correctCount'] as int) < 0 ||
          (data['correctCount'] as int) > 5 ||
          data['submittedAt'] is! Timestamp) {
        throw StateError('Invalid Class B attempt record.');
      }

      setState(() {
        result = data;
      });
    } on FirebaseException catch (e) {
      if (!mounted) return;

      setState(() {
        error = 'Firestore error: ${e.code}';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  @override
  void dispose() {
    roundIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Previous Attempt'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Retrieve Saved Quiz Result',
            style: TextStyle(
              fontSize: 23,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: roundIdController,
            decoration: const InputDecoration(
              labelText: 'Round ID',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: loading ? null : retrieveAttempt,
            child: const Text('Retrieve from Server'),
          ),
          if (loading)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(
                child: CircularProgressIndicator(),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                error!,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          if (result != null) ...[
            const SizedBox(height: 20),
            const Icon(
              Icons.verified,
              size: 60,
              color: Colors.green,
            ),
            const Text(
              'Cloud verified',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                color: Colors.green,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Score: ${result!['correctCount']} / 5',
              style: const TextStyle(fontSize: 22),
            ),
            Text('Round ID: ${roundIdController.text.trim()}'),
            Text('Variant: ${result!['variant']}'),
            Text(
              'Submitted: '
              '${(result!['submittedAt'] as Timestamp).toDate()}',
            ),
          ],
        ],
      ),
    );
  }
}
