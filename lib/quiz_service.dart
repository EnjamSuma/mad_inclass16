
import 'dart:convert';
import 'package:http/http.dart' as http;

class QuizQuestion {
  final String category;
  final String question;
  final String correctAnswer;
  final String incorrectAnswer;

  const QuizQuestion({
    required this.category,
    required this.question,
    required this.correctAnswer,
    required this.incorrectAnswer,
  });
}

class QuizService {
  static const apiUrl =
      'https://opentdb.com/api.php?amount=5&category=17&difficulty=medium&type=boolean&encode=url3986';

  static DateTime? lastRequest;

  static Future<List<QuizQuestion>> fetchQuestions() async {
    final now = DateTime.now();

    if (lastRequest != null &&
        now.difference(lastRequest!) <
            const Duration(seconds: 5)) {
      throw Exception(
        'Please wait 5 seconds before requesting again.',
      );
    }

    lastRequest = now;

    final response = await http
        .get(Uri.parse(apiUrl))
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception(
        'HTTP error ${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body);

    if (data is! Map<String, dynamic> ||
        data['response_code'] != 0 ||
        data['results'] is! List ||
        (data['results'] as List).length != 5) {
      throw const FormatException(
        'Invalid response: expected five questions.',
      );
    }

    String decode(dynamic value) {
      if (value is! String || value.isEmpty) {
        throw const FormatException('Missing text field');
      }

      final decoded = Uri.decodeComponent(value);

      if (decoded.trim().isEmpty) {
        throw const FormatException('Empty decoded field');
      }

      return decoded;
    }

    final questions = <QuizQuestion>[];

    for (final item in data['results'] as List) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Invalid question');
      }

      final category = decode(item['category']);
      final question = decode(item['question']);
      final correct = decode(item['correct_answer']);

      final incorrect = item['incorrect_answers'];

      if (incorrect is! List || incorrect.length != 1) {
        throw const FormatException('Invalid answers');
      }

      final wrong = decode(incorrect.first);

      if (category != 'Science & Nature' ||
          item['difficulty'] != 'medium' ||
          item['type'] != 'boolean' ||
          correct == wrong ||
          {correct, wrong}.length != 2 ||
          !{correct, wrong}.containsAll({'True', 'False'})) {
        throw const FormatException(
          'Question does not match Class B requirements',
        );
      }

      questions.add(
        QuizQuestion(
          category: category,
          question: question,
          correctAnswer: correct,
          incorrectAnswer: wrong,
        ),
      );
    }

    return questions;
  }
}
