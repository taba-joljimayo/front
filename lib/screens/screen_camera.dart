import 'dart:async';
import 'dart:convert';

import 'package:dart_openai/dart_openai.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class CameraScreen extends StatefulWidget {
  final CameraDescription camera;

  const CameraScreen({required this.camera});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  late CameraController _cameraController;
  late Future<void> _initializeControllerFuture;
  late WebSocketChannel _channel;

  final SpeechToText _flutterStt = SpeechToText();
  final FlutterTts _flutterTts = FlutterTts();

  bool _sttEnabled = false;
  bool _isListening = false; // STT 활성 상태
  bool _isSpeaking = false; // TTS 활성 상태
  bool _isProcessing = false; // API 호출 중 상태
  bool _isConversationActive = false; // 대화 상태
  bool _isStreaming = false; // 실시간 전송 상태
  Timer? _streamTimer; // 실시간 전송용 타이머

  String _currentLocaleId = '';

  List<Map<String, String>> _conversationHistory = []; // 대화 히스토리

  @override
  void initState() {
    super.initState();
    _cameraController = CameraController(
      widget.camera,
      ResolutionPreset.high,
    );
    _initializeControllerFuture = _cameraController.initialize();


    // WebSocket 초기화
    try {
      _channel = WebSocketChannel.connect(
        Uri.parse('ws://192.168.0.15:8080/image'),
      );

      // WebSocket 데이터 수신 및 에러 처리
      _channel.stream.listen(
        (data) {
          //print("서버로부터 데이터 수신: $data");
        },
        onError: (error) {
          //print("WebSocket 에러: $error");
          // 필요한 경우 재연결 로직 추가
        },
        onDone: () {
          //print("WebSocket 연결 종료");
          // 필요한 경우 재연결 로직 추가
        },
        //cancelOnError: false, // 에러 발생 시 스트림이 닫히지 않도록 설정(추가 4)
      );
    } catch (e) {
      //print("WebSocket 연결 중 예외 발생: $e");
      // 예외 발생 시에도 앱이 종료되지 않도록 처리
    }
    _initStt();
    _initTts();
    _initOpenAI();
  }

  @override
  void dispose() {
    _cameraController.dispose();
    _channel.sink.close();
    super.dispose();
  }

  Future<void> _captureAndSendImage() async {
    try {
      await _initializeControllerFuture;

      final image = await _cameraController.takePicture();
      final bytes = await image.readAsBytes();
      final base64Image = base64Encode(bytes);

      // 웹소켓으로 이미지 전송
      _channel.sink.add(base64Image);
      //print("이미지 전송 완료");
      //print("Base64 Image (First 100 chars): ${base64Image.length}");
    } catch (e) {
      //print("Error: $e");
    }
  }

  void startStreaming() {
    if (_isStreaming) return;
    _isStreaming = true;

    //타이머 시작 (1초)
    _streamTimer = Timer.periodic(Duration(milliseconds: 300), (timer) async {
      if (!_isStreaming) {
        timer.cancel();
        return;
      }
      await _captureAndSendImage();
    });

    print("이미지 실시간 전송 시작");
  }

  void stopStreaming() {
    if (!_isStreaming) return;
    _streamTimer?.cancel();
    print("이미지 실시간 전송 중단");
  }

  void _initStt() async {
    _sttEnabled = await _flutterStt.initialize(
      onStatus: (status) {
        //print('SpeechToText Status: $status');
        if (status == "listening") {
          if (!_isListening) {
            _isListening = true;
            //print("STT가 시작되었습니다.");
          }
        } else if (status == "notListening") {
          if (_isListening) {
            _isListening = false;
            //print("STT가 중단되었습니다.");
            // 현재 TTS나 처리 중이 아니라면 STT 재시작
            if (!_isSpeaking && !_isProcessing) {
              Future.delayed(Duration(milliseconds: 500), () {
                _startListening();
              });
            }
          }
        }
      },
      onError: (error) {
        //print('SpeechToText Error: $error');
        _isListening = false;
        // 에러 발생 시 STT 재시작
        if (!_isSpeaking && !_isProcessing) {
          Future.delayed(Duration(seconds: 1), () {
            _startListening();
          });
        }
      },
    );

    if (_sttEnabled) {
      //print("SpeechToText initialized successfully.");
      var systemLocale = await _flutterStt.systemLocale();
      _currentLocaleId = systemLocale?.localeId ?? 'ko_KR';
      _startListening();
    } else {
      //print("SpeechToText initialization failed.");
    }
  }

  // TTS 초기화
  void _initTts() async {
    // 사용 가능한 언어 목록 출력
    List<dynamic> languages = await _flutterTts.getLanguages;
    //print("사용 가능한 TTS 언어 목록: $languages");

    // 언어 설정
    await _flutterTts.setLanguage('ko-KR');
    print("TTS 언어가 'ko-KR'로 설정되었습니다.");

    await _flutterTts.setSpeechRate(0.8);
    await _flutterTts.setPitch(1.0);
    await _flutterTts.awaitSpeakCompletion(true);

    // TTS 상태 및 에러 콜백 추가
    _flutterTts.setStartHandler(() {
      //print("TTS가 시작되었습니다.");
    });

    _flutterTts.setCompletionHandler(() {
      //print("TTS가 완료되었습니다.");
    });

    _flutterTts.setErrorHandler((msg) {
      //print("TTS 에러: $msg");
    });
  }

  // OpenAI 초기화
  void _initOpenAI() async {
    await dotenv.load(fileName: '.env');
    String? apiKey = dotenv.env['OPEN_AI_API_KEY'];
    if (apiKey != null && apiKey.isNotEmpty) {
      OpenAI.apiKey = apiKey;
      print("OpenAI API 키가 설정되었습니다.");
    } else {
      print("OpenAI API 키를 찾을 수 없습니다.");
    }
  }
  // 지연시간 설정
  Future<void> _startListening() async {

    if (_sttEnabled && !_isListening && !_isSpeaking && !_isProcessing) {
      print("Starting STT listening...");
      _isListening = true;
      try {
        await _flutterStt.listen(
          onResult: _onSpeechResult,
          localeId: 'ko_KR',
          listenFor: Duration(seconds: 30),
          pauseFor: Duration(seconds: 5),

        );
      } catch (e) {
        print("Error during STT listening: $e");
        _isListening = false;

        // 지연을 두고 다시 시도
        Future.delayed(Duration(seconds: 1), () {
          _startListening();
        });
      }
    } else {
      print('STT is not enabled or already listening.');
    }
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    // 디버깅(추가 1)
    /*print(
        "Current State - isListening: $_isListening, isSpeaking: $_isSpeaking, isProcessing: $_isProcessing, sttEnabled: $_sttEnabled");*/
    // 최종 결과인 경우에만 처리
    if (result.finalResult) {
      String userInput = result.recognizedWords.trim();
      print("Recognized Final Text: $userInput");

      // 제외할 단어 또는 문구 목록
      List<String> excludedPhrases = [
        "좌회전", "우회전", "직진", "500미터 앞에서", "목적지", "경로를 재탐색합니다", "안내를 시작합니다"
        // 네비게이션 안내에서 자주 사용되는 문구들 추가
      ];

      // 제외할 단어가 포함되어 있는지 확인
      bool containsExcludedPhrase =
          excludedPhrases.any((phrase) => userInput.contains(phrase));

      if (!_isProcessing && !_isSpeaking) {
        if (!_isConversationActive && userInput.contains("대화 시작")) {
          _isConversationActive = true;
          _isListening = false;
          _flutterStt.stop(); // STT 중단
          _collisionST("대화를 시작합니다. 말씀하세요.");
          Future.delayed(Duration(seconds: 1), () {
            _startListening();
          });
          return;
        }

        if (_isConversationActive) {
          _isListening = false;
          _flutterStt.stop(); // STT 중단

          // 대화 히스토리에 사용자 입력 추가
          _conversationHistory.add({'role': 'user', 'content': userInput});

          // OpenAI API 호출
          _isProcessing = true;
          generateAnswer().then((gptResponse) {
            _isProcessing = false;

            if (gptResponse != null && gptResponse.isNotEmpty) {
              _conversationHistory
                  .add({'role': 'assistant', 'content': gptResponse});
              _collisionST(gptResponse);
            } else {
              _collisionST("죄송합니다, 응답을 생성할 수 없습니다.");
            }
          });
        }
      }
    } else {
      print("Partial Recognized Text: ${result.recognizedWords}");
    }
  }

  /*Future<void> _collisionST(String text) async {
    if (_isListening) {
      await _flutterStt.stop(); // STT 중단
      _isListening = false;
    }
    _isSpeaking = true;

    // TTS 에러 핸들링 추가
    try {
      await _flutterTts.speak(text);
    } catch (e) {
      print("TTS 실행 중 에러 발생: $e");
    } finally {
      _isSpeaking = false; // TTS 완료 또는 실패 시

      // TTS가 완료되었으므로 STT 재시작
      Future.delayed(Duration(seconds: 1), () {
        _startListening();
      });
    }
  }*/
  Future<void> _collisionST(String text) async {
    print("TTS 함수 호출됨. 출력할 텍스트: $text");

    if (_isListening) {
      await _flutterStt.stop(); // STT 중단
      _isListening = false;
      print("STT 중단됨.");
    }
    _isSpeaking = true;

    // TTS 에러 핸들링 추가
    try {
      // 텍스트에서 이모지나 특수문자 제거
      String sanitizedText =
          text.replaceAll(RegExp(r'[^\u0000-\u007F\uAC00-\uD7A3]+'), '');
      print("TTS에 전달될 텍스트: $sanitizedText");

      await _flutterTts.speak(sanitizedText);
      print("TTS 실행 완료.");
    } catch (e) {
      print("TTS 실행 중 에러 발생: $e");
    } finally {
      _isSpeaking = false; // TTS 완료 또는 실패 시

      // TTS가 완료되었으므로 STT 재시작
      Future.delayed(Duration(seconds: 1), () {
        _startListening();
      });
    }
  }

  // TTS 실행
  Future<void> _collisionST(String text) async {
    if (_isListening) {
      await _flutterStt.stop(); // STT 중단
      _isListening = false;
    }
    _isSpeaking = true;
    await _flutterTts.speak(text);
    _isSpeaking = false; // TTS 완료
  }

  // GPT 응답 생성
  Future<String?> generateAnswer() async {
    const String systemPrompt =
        "너는 운전 중인 사용자의 졸음을 깨우는 데 도움을 주는 챗봇 역할을 하고 있어. 친근한 친구처럼 다정하고 재미있게 대화를 이어가며, 운전자가 졸음을 이겨낼 수 있도록 도와줘. 답변은 항상 간단하고 명확하게 두 문장 이내로 작성하며 사용자를 지칭하거나 '안녕'같은 인사는 하지마, 사용자가 웃거나 대답할 수 있는 질문을 포함해. 예를 들어, '졸리면 안 돼! 내가 재미있는 얘기 하나 해줄까?' 또는 '지금 주변에 뭐 보여? 바깥 풍경 어때?'와 같이 대화해. 네 목표는 사용자가 깨어 있을 수 있도록 대화를 유도하는 거야. 또한, 답변은 명령조가 아니라 부드럽고 유쾌한 어투를 유지해야 해.너도 대답은 꼭 하고 질문도 다양하게 생각해봐. 먼저 어떤것에 흥미가 있는지 물어보고 너의 생각도 말하며 대화를 이어나가면 좋을거 같아. 요즘 시사나 문제에 대해 토론을 해보는 것도 좋을것 같아.";
    try {
      // 디머깅 추가(추가 2)
      print("OPEN AI API 호출 시작");

      final response = await OpenAI.instance.chat.create(
        model: "gpt-4o-mini",
        messages: [
          OpenAIChatCompletionChoiceMessageModel(
            role: OpenAIChatMessageRole.system,
            content: [
              OpenAIChatCompletionChoiceMessageContentItemModel.text(
                  systemPrompt
              )
            ],
          ),
          ..._conversationHistory.map((message) {
            return OpenAIChatCompletionChoiceMessageModel(
              role: message['role'] == 'user'
                  ? OpenAIChatMessageRole.user
                  : OpenAIChatMessageRole.assistant,
              content: [
                OpenAIChatCompletionChoiceMessageContentItemModel.text(
                    message['content']!
                )
              ],
            );
          }).toList(),
        ],
        maxTokens: 100,
      );

      String? gptResponse = response.choices.first.message.content?.first.text;
      //디버깅 추가 (추가 2)
      print("OpenAI API 응답: $gptResponse");
      return gptResponse;
    } catch (e, stackTrace) {
      print("OpenAI API 호출 중 에러 발생: $e");
      print("스택 트레이스: $stackTrace");
      _isProcessing = false; // 상태 변수 업데이트

      // 예외 발생 시 STT 재시작(수정 2)
      if (!_isListening && !_isSpeaking) {
        Future.delayed(Duration(seconds: 1), () {
          _startListening();
        });
      }
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
          Text(
            _isConversationActive ? "대화 중..." : "대화 대기 중",
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: () {
                  if (_isStreaming) {
                    stopStreaming();
                  } else {
                    startStreaming();
                  }
                },
                child:
                    Text(_isStreaming ? "Stop Streaming" : "Start Streaming"),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
