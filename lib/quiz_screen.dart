import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'quiz_service.dart';
import 'previous_attempt_screen.dart';

enum SaveStatus {
  ready,
  submitting,
  verifying,
  cloudVerified,
  saveUnknown,
  permissionDenied,
  verificationUnavailable,
  collision,
}

class QuizScreen extends StatefulWidget {
  final User user;

  const QuizScreen({super.key, required this.user});

  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  List<QuizQuestion> questions = [];
  List<String?> answers = [];

  int currentIndex = 0;
  bool loading = true;
  bool completed = false;

  String? error;
  String? roundId;
  String? message;

  SaveStatus status = SaveStatus.ready;
  bool commitAcknowledged = false;
  bool operationActive = false;

  Map<String, dynamic>? frozenFields;

  // G03: Reject stale asynchronous question responses.
  int _questionRequestId = 0;

  // All fault injections are disabled in the release version.
  static const bool injectVerificationFailure = false;
  static const bool injectUnavailable = false;
  static const bool injectResourceExhausted = false;

  bool injectionUsed = false;

  @override
  void initState() {
    super.initState();
    loadQuestions();
  }

  @override
  void didUpdateWidget(covariant QuizScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.user.uid != widget.user.uid) {
      _questionRequestId++;
      operationActive = false;
      status = SaveStatus.ready;
      loadQuestions();
    }
  }

  @override
  void dispose() {
    _questionRequestId++;
    super.dispose();
  }

  bool get identityValid =>
      FirebaseAuth.instance.currentUser?.uid == widget.user.uid;

  bool get unresolved =>
      status == SaveStatus.submitting ||
      status == SaveStatus.verifying ||
      status == SaveStatus.saveUnknown ||
      status == SaveStatus.verificationUnavailable ||
      status == SaveStatus.permissionDenied;

  DocumentReference<Map<String, dynamic>> get attemptRef {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(widget.user.uid)
        .collection('attempts')
        .doc(roundId!);
  }

  Future<void> loadQuestions() async {
    if (operationActive || unresolved || !identityValid) {
      return;
    }

    final requestUserUid = widget.user.uid;
    final requestId = ++_questionRequestId;

    setState(() {
      loading = true;
      completed = false;
      error = null;
      message = null;
      currentIndex = 0;
      questions = [];
      answers = [];
      roundId = null;
      status = SaveStatus.ready;
      commitAcknowledged = false;
      frozenFields = null;
      injectionUsed = false;
    });

    bool requestIsCurrent() {
      return mounted &&
          identityValid &&
          _questionRequestId == requestId &&
          widget.user.uid == requestUserUid;
    }

    try {
      final result = await QuizService.fetchQuestions();

      if (!requestIsCurrent()) return;

      setState(() {
        questions = result;
        answers = List<String?>.filled(5, null);

        roundId = FirebaseFirestore.instance
            .collection('users')
            .doc(requestUserUid)
            .collection('attempts')
            .doc()
            .id;

        loading = false;
      });
    } catch (e) {
      if (!requestIsCurrent()) return;

      setState(() {
        error = e.toString();
        loading = false;
      });
    }
  }

  void selectAnswer(String value) {
    if (loading ||
        completed ||
        !identityValid ||
        answers[currentIndex] != null) {
      return;
    }

    setState(() {
      answers[currentIndex] = value;
    });
  }

  void continueQuiz() {
    if (!identityValid || answers[currentIndex] == null) {
      return;
    }

    setState(() {
      if (currentIndex < 4) {
        currentIndex++;
      } else {
        completed = true;
      }
    });
  }

  int get score {
    int count = 0;

    for (int i = 0; i < questions.length; i++) {
      if (answers[i] == questions[i].correctAnswer) {
        count++;
      }
    }

    return count;
  }

  Map<String, dynamic> get fixedFields => {
    'schemaVersion': 1,
    'variant': 'B',
    'categoryId': 17,
    'questionCount': 5,
    'correctCount': score,
  };

  bool fieldsMatch(Map<String, dynamic> data) {
    final expected = frozenFields!;

    for (final key in expected.keys) {
      if (data[key] != expected[key]) {
        return false;
      }
    }

    return true;
  }

  Future<void> submitAttempt() async {
    if (!completed || operationActive || !identityValid || roundId == null) {
      return;
    }

    if (status == SaveStatus.cloudVerified || status == SaveStatus.collision) {
      return;
    }

    operationActive = true;
    frozenFields ??= Map.unmodifiable(fixedFields);

    final submissionUid = widget.user.uid;
    final submissionRoundId = roundId!;

    final reference = FirebaseFirestore.instance
        .collection('users')
        .doc(submissionUid)
        .collection('attempts')
        .doc(submissionRoundId);

    bool submissionIsCurrent() {
      return mounted &&
          identityValid &&
          widget.user.uid == submissionUid &&
          roundId == submissionRoundId;
    }

    setState(() {
      status = SaveStatus.submitting;
      message = 'Checking and saving this round...';
    });

    try {
      // Check the original round before attempting another write.
      final existing = await reference.get(
        const GetOptions(source: Source.server),
      );

      if (!submissionIsCurrent()) return;

      if (existing.exists) {
        if (!fieldsMatch(existing.data()!)) {
          setState(() {
            status = SaveStatus.collision;
            message = 'Collision: existing score differs.';
          });
          return;
        }

        commitAcknowledged = true;
        await verifyAttempt();
        return;
      }

      final payload = {
        ...frozenFields!,
        'submittedAt': FieldValue.serverTimestamp(),
      };

      if (injectUnavailable) {
        throw FirebaseException(
          plugin: 'cloud_firestore',
          code: 'unavailable',
          message: 'Simulated service unavailable',
        );
      }

      if (injectResourceExhausted) {
        throw FirebaseException(
          plugin: 'cloud_firestore',
          code: 'resource-exhausted',
          message: 'Simulated resource exhaustion',
        );
      }

      // Create once using a Firestore transaction.
      await FirebaseFirestore.instance
          .runTransaction((transaction) async {
            final snapshot = await transaction.get(reference);

            if (snapshot.exists) {
              if (!fieldsMatch(snapshot.data()!)) {
                throw StateError('Round ID collision');
              }
            } else {
              transaction.set(reference, payload);
            }
          })
          .timeout(const Duration(seconds: 10));

      if (!submissionIsCurrent()) return;

      commitAcknowledged = true;
      await verifyAttempt();
    } on FirebaseException catch (e) {
      if (!submissionIsCurrent()) return;

      setState(() {
        if (e.code == 'permission-denied') {
          status = SaveStatus.permissionDenied;
          message = 'Permission denied: ${e.message ?? e.code}';
        } else {
          status = SaveStatus.saveUnknown;
          message =
              'Save outcome uncertain (${e.code}). '
              'Retry with the same round ID.';
        }
      });
    } catch (e) {
      if (!submissionIsCurrent()) return;

      setState(() {
        if (e is StateError) {
          status = SaveStatus.collision;
          message = 'Collision: the saved payload differs.';
        } else {
          status = SaveStatus.saveUnknown;
          message =
              'Save outcome unknown. '
              'Reconcile the original round before retrying.';
        }
      });
    } finally {
      operationActive = false;
    }
  }

  Future<void> verifyAttempt() async {
    if (!mounted || !identityValid || roundId == null) {
      return;
    }

    final verificationUid = widget.user.uid;
    final verificationRoundId = roundId!;

    final reference = FirebaseFirestore.instance
        .collection('users')
        .doc(verificationUid)
        .collection('attempts')
        .doc(verificationRoundId);

    bool verificationIsCurrent() {
      return mounted &&
          identityValid &&
          widget.user.uid == verificationUid &&
          roundId == verificationRoundId;
    }

    setState(() {
      status = SaveStatus.verifying;
      message = 'Verifying exact server record...';
    });

    try {
      if (injectVerificationFailure && !injectionUsed) {
        injectionUsed = true;

        throw FirebaseException(
          plugin: 'cloud_firestore',
          code: 'permission-denied',
          message: 'Injected verification failure',
        );
      }

      final result = await reference
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));

      if (!verificationIsCurrent()) return;

      final data = result.data();

      final valid =
          result.exists &&
          data != null &&
          data.length == 6 &&
          fieldsMatch(data) &&
          data['submittedAt'] is Timestamp &&
          !result.metadata.hasPendingWrites &&
          !result.metadata.isFromCache;

      setState(() {
        if (valid) {
          status = SaveStatus.cloudVerified;
          message = 'Cloud verified';
        } else {
          status = SaveStatus.verificationUnavailable;
          message =
              'Server response did not match '
              'the expected record.';
        }
      });
    } on FirebaseException catch (e) {
      if (!verificationIsCurrent()) return;

      setState(() {
        status = e.code == 'permission-denied'
            ? SaveStatus.permissionDenied
            : SaveStatus.verificationUnavailable;

        message = commitAcknowledged
            ? 'Write acknowledged; verification unavailable '
                  '(${e.code}).'
            : 'Verification unavailable (${e.code}).';
      });
    } catch (_) {
      if (!verificationIsCurrent()) return;

      setState(() {
        status = SaveStatus.verificationUnavailable;
        message =
            'Verification unavailable. '
            'Retry the server read.';
      });
    }
  }

  Future<void> retry() async {
    if (operationActive || !identityValid) return;

    if (commitAcknowledged) {
      operationActive = true;

      try {
        await verifyAttempt();
      } finally {
        operationActive = false;
      }
    } else {
      await submitAttempt();
    }
  }

  Widget buildQuiz() {
    final question = questions[currentIndex];
    final selected = answers[currentIndex];

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Question ${currentIndex + 1} of 5',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        LinearProgressIndicator(value: (currentIndex + 1) / 5),
        const SizedBox(height: 30),
        Text(question.question, style: const TextStyle(fontSize: 22)),
        const SizedBox(height: 30),
        for (final value in ['True', 'False'])
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ElevatedButton(
              onPressed: selected == null ? () => selectAnswer(value) : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: selected == null
                    ? null
                    : value == question.correctAnswer
                    ? Colors.green.shade100
                    : value == selected
                    ? Colors.red.shade100
                    : null,
                padding: const EdgeInsets.all(16),
              ),
              child: Text(value),
            ),
          ),
        if (selected != null)
          Text(
            selected == question.correctAnswer
                ? '✓ Correct!'
                : '✗ Incorrect. Correct: '
                      '${question.correctAnswer}',
            style: TextStyle(
              fontSize: 17,
              color: selected == question.correctAnswer
                  ? Colors.green.shade800
                  : Colors.red.shade800,
            ),
          ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: selected == null ? null : continueQuiz,
          child: Text(currentIndex == 4 ? 'Finish Quiz' : 'Continue'),
        ),
      ],
    );
  }

  Widget buildResults() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Quiz Complete!',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Text('Your Score: $score / 5', style: const TextStyle(fontSize: 23)),
        const SizedBox(height: 20),
        const Text(
          'Answer Review',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        for (int i = 0; i < questions.length; i++)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${i + 1}. ${questions[i].question}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text('Your answer: ${answers[i]}'),
                  Text(
                    'Correct answer: '
                    '${questions[i].correctAnswer}',
                  ),
                  Text(
                    answers[i] == questions[i].correctAnswer
                        ? '✓ Correct'
                        : '✗ Incorrect',
                    style: TextStyle(
                      color: answers[i] == questions[i].correctAnswer
                          ? Colors.green
                          : Colors.red,
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 20),
        Text(
          message ?? 'Ready to submit to Firestore.',
          style: const TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 12),
        if (roundId != null) SelectableText('Round ID: $roundId'),
        const SizedBox(height: 20),
        if (status == SaveStatus.ready)
          ElevatedButton(
            onPressed: submitAttempt,
            child: const Text('Submit to Cloud'),
          ),
        if (status == SaveStatus.submitting || status == SaveStatus.verifying)
          const Center(child: CircularProgressIndicator()),
        if (status == SaveStatus.saveUnknown ||
            status == SaveStatus.permissionDenied ||
            status == SaveStatus.verificationUnavailable)
          ElevatedButton(
            onPressed: operationActive ? null : retry,
            child: Text(
              commitAcknowledged
                  ? 'Retry Server Verification'
                  : 'Reconcile and Retry',
            ),
          ),
        if (status == SaveStatus.cloudVerified)
          const Text(
            '✓ Cloud verified',
            style: TextStyle(
              color: Colors.green,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: unresolved || operationActive ? null : loadQuestions,
          child: const Text('Play Again'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Science Signal'),
        actions: [
          IconButton(
            tooltip: 'Retrieve previous attempt',
            icon: const Icon(Icons.history),
            onPressed: unresolved || operationActive
                ? null
                : () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            PreviousAttemptScreen(user: widget.user),
                      ),
                    );
                  },
          ),
          IconButton(
            tooltip: 'Sign Out',
            icon: const Icon(Icons.logout),
            onPressed: unresolved || operationActive
                ? null
                : () async {
                    await FirebaseAuth.instance.signOut();
                  },
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(error!),
                  ElevatedButton(
                    onPressed: loadQuestions,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          : completed
          ? buildResults()
          : buildQuiz(),
    );
  }
}
