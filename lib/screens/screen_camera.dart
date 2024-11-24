import 'dart:convert';

import 'package:dart_openai/dart_openai.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class CameraScreen extends StatefulWidget {
  final CameraDescription camera;

  const CameraScreen({required this.camera});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  late CameraController _cameraController;
  late Future<void> _initializeControllerFuture;

  final SpeechToText _speech = SpeechToText();
  final FlutterTts _flutterTts = FlutterTts();

  bool _speechEnabled = false;
  bool _isListening = false;

  @override
  void initState() {
    super.initState();
    _cameraController = CameraController(
      widget.camera,
      ResolutionPreset.high,
    );
    _initializeControllerFuture = _cameraController.initialize();
    _initSpeech();
    _initTts();
    _initOpenAI();
  }

  @override
  void dispose() {
    _cameraController.dispose();
    super.dispose();
  }

  // 음성 인식 초기화
  void _initSpeech() async {
    await Permission.microphone.request();
    _speechEnabled = await _speech.initialize(
      onStatus: (status) => print('Speech status: $status'),
      onError: (error) => print('Speech error: $error'),
    );
    setState(() {});
  }

  // TTS 초기화
  void _initTts() async {
    await _flutterTts.setLanguage('ko-KR');
    await _flutterTts.setSpeechRate(0.8);
    await _flutterTts.setPitch(1.0);
    await _flutterTts.awaitSpeakCompletion(true);
  }

  // OpenAI 초기화
  void _initOpenAI() async {
    await dotenv.load(fileName: '.env');
    String? apiKey = dotenv.env['OPEN_AI_API_KEY'];
    if (apiKey != null && apiKey.isNotEmpty) {
      OpenAI.apiKey = apiKey;
    } else {
      print("OpenAI API 키를 찾을 수 없습니다.");
    }
  }

  // 음성 인식 토글
  void _toggleListening() async {
    if (_isListening) {
      await _speech.stop();
      setState(() {
        _isListening = false;
      });
    } else {
      if (_speechEnabled) {
        await _speech.listen(
          onResult: _onSpeechResult,
          listenFor: const Duration(seconds: 30),
          pauseFor: const Duration(seconds: 5),
          localeId: 'ko_KR',
        );
        setState(() {
          _isListening = true;
        });
      } else {
        print('Speech recognition is not enabled.');
      }
    }
  }

  // 음성 인식 결과 처리
  void _onSpeechResult(SpeechRecognitionResult result) async {
    String userInput = result.recognizedWords;
    print("Recognized Text: $userInput");

    if (userInput.isNotEmpty) {
      String? gptResponse = await generateAnswer(userInput);

      if (gptResponse != null && gptResponse.isNotEmpty) {
        await _flutterTts.speak(gptResponse);
      } else {
        await _flutterTts.speak("죄송합니다, 응답을 생성할 수 없습니다.");
      }
    }
  }

  // GPT 응답 생성
  Future<String?> generateAnswer(String prompt) async {
    try {
      final response = await OpenAI.instance.chat.create(
        model: "gpt-4o-mini",
        messages: [
          OpenAIChatCompletionChoiceMessageModel(
            role: OpenAIChatMessageRole.system,
            content: [
              OpenAIChatCompletionChoiceMessageContentItemModel.text(
                "너는 운전 중인 사용자의 졸음을 깨우는 데 도움을 주는 챗봇 역할을 하고 있어. 친근한 친구처럼 다정하고 재미있게 대화를 이어가며, 운전자가 졸음을 이겨낼 수 있도록 도와줘. 답변은 항상 간단하고 명확하게 두 문장 이내로 작성하며 사용자를 지칭하거나 '안녕'같은 인사는 하지마, 사용자가 웃거나 대답할 수 있는 질문을 포함해. 예를 들어, '졸리면 안 돼! 내가 재미있는 얘기 하나 해줄까?' 또는 '지금 주변에 뭐 보여? 바깥 풍경 어때?'와 같이 대화해. 네 목표는 사용자가 깨어 있을 수 있도록 대화를 유도하는 거야. 또한, 답변은 명령조가 아니라 부드럽고 유쾌한 어투를 유지해야 해."
              ),
            ],
          ),
          OpenAIChatCompletionChoiceMessageModel(
            role: OpenAIChatMessageRole.user,
            content: [
              OpenAIChatCompletionChoiceMessageContentItemModel.text(
                prompt,
              ),
            ],
          ),
        ],
        maxTokens: 100,
      );

      // content가 리스트로 반환될 경우 첫 번째 항목을 가져옴
      String? gptResponse = response.choices.first.message.content?.first.text;

      return gptResponse;
    } catch (e) {
      print("Error: $e");
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(
          '졸지마요',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
        ),
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(20)),
            alignment: Alignment.center,
            width: MediaQuery.of(context).size.width,
            height: 550,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: FutureBuilder<void>(
                future: _initializeControllerFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.done) {
                    return CameraPreview(_cameraController);
                  } else {
                    return Center(child: CircularProgressIndicator());
                  }
                },
              ),
            ),
          ),
          SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                onPressed: _toggleListening,
                icon: Icon(
                  _isListening ? Icons.mic : Icons.mic_off,
                  size: 50,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
