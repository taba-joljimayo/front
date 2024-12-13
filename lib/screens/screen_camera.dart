import 'dart:async';
import 'dart:math';

import 'package:image/image.dart' as img;

import 'package:dart_openai/dart_openai.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

class CameraScreen extends StatefulWidget {
  final CameraDescription camera;

  const CameraScreen({required this.camera});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  late CameraController _cameraController;
  late Future<void> _initializeControllerFuture;

  final SpeechToText _flutterStt = SpeechToText();
  final FlutterTts _flutterTts = FlutterTts();

  bool _sttEnabled = false;
  bool _isListening = false;
  bool _isSpeaking = false;
  bool _isProcessing = false;
  bool _isConversationActive = false;

  bool _isStreaming = false;
  Timer? _frameTimer;
  bool _isProcessingFrame = false;

  String _currentLocaleId = '';
  List<Map<String, String>> _conversationHistory = [];

  Timer? _responseWaitTimer;
  bool _awaitingUserResponse = false;
  int _retryCount = 0;
  int _maxRetryCount = 3;

  // socket.io 객체
  late io.Socket _socket;

  // socket에서 오는 'result' 이벤트를 Stream으로 노출하기 위한 컨트롤러
  final _socketController = StreamController<dynamic>();

  @override
  void initState() {
    super.initState();
    _cameraController = CameraController(
      widget.camera,
      ResolutionPreset.high,
    );
    _initializeControllerFuture = _cameraController.initialize();

    // STT, TTS, OpenAI 초기화
    _initStt();
    _initTts();
    _initOpenAI();

    // Socket.io 초기화
    _initSocket();

    // 소켓으로부터 오는 result 이벤트를 비동기 처리할 핸들러 시작
    _handleSocketResults();
  }

  @override
  void dispose() {
    _cameraController.dispose();
    _socket.disconnect();
    _socketController.close(); // 스트림 컨트롤러 닫기
    super.dispose();
  }

  void _initSocket() {
    _socket = io.io(
      'http://192.168.0.7:5000',
      <String, dynamic>{
        'transports': ['websocket'],
        'path': '/socket.io',
        'secure': true,
        'autoConnect': true,
        'timeout': 10000,
        //'reconnetcion': true,
        //'reconnectionAttempts': 5,
        //'reconnectionDelay': 2000,
      },
    );

    _socket.onConnect((_) {
      print('Socket.IO 서버에 연결되었습니다.');
    });

    _socket.onConnectError((error) => print('연결 오류: $error'));

    // 'result' 이벤트가 오면 _socketController에 add
    _socket.on('result', (data) {
      _socketController.add(data);
    });

    _socket.onError((error) {
      //print("Socket.IO 에러: $error");
    });

    _socket.onDisconnect((_) {
      print("Socket.IO 연결 종료");
    });
  }

  int closedEyesCount = 0; // 눈 감은 상태 카운트

  Future<void> _handleSocketResults() async {
    await for (final data in _socketController.stream) {
      try {
        // 수신 데이터 출력
        print("서버로부터 데이터 수신: $data (타입: ${data.runtimeType})");

        // 데이터가 정수인지 확인
        if (data is int) {
          final int result = data;

          if (result == 1) {
            // 눈을 뜬 경우
            closedEyesCount = 0; // 카운트를 0으로 리셋
            print("두 눈을 뜸, 카운트 리셋: $closedEyesCount");
          } else if (result == 0) {
            // 눈을 감음 경우
            closedEyesCount++; // 카운트 증가
            print("두 눈을 감음 카운트: $closedEyesCount");

            if (closedEyesCount == 10) {
              // 30번 연속 눈 감음 감지 -> 챗봇이 먼저 말 걸기
              print("30번 눈 감음 연속 감지, 대화 시작");
              closedEyesCount = 0; // 카운트 리셋
              _startConversation(); // 너가 먼저 말을 거는 로직
            }
          } else {
            closedEyesCount++;
            print("예상치 못한 값: $result");
          }
        } else {
          print("잘못된 데이터 형식: ${data.runtimeType}, 값: $data");
        }
      } catch (e) {
        print("서버로부터 수신한 데이터 처리 중 오류 발생: $e");
      }
    }
  }

  void _startConversation() async {
    // 챗봇이 먼저 말 걸기
    await _collisionST("졸면 안 돼! 내가 재미있는 얘기 하나 해줄까?");

    // 여기서 OpenAI API를 호출하여 자동으로 응답을 생성
    String? gptResponse = await generateAnswer();

    if (gptResponse != null && gptResponse.isNotEmpty) {
      // OpenAI 응답을 TTS로 출력
      await _collisionST(gptResponse);
    } else {
      // 응답 생성 실패 시 대체 문구 출력
      await _collisionST("지금은 딱히 생각나는 이야기가 없어. 혹시 바깥 풍경이 어때?");
    }
  }

  Future<void> _startImageStreaming() async {
    if (_isStreaming) return;

    try {
      await _initializeControllerFuture;

      _isStreaming = true;

      // 타이머로 캡처 주기 설정
      _frameTimer = Timer.periodic(Duration(milliseconds: 300), (timer) async {
        if (!_isStreaming || _isProcessingFrame) return;

        _isProcessingFrame = true;

        try {
          // 현재 카메라 프레임 캡처
          final cameraImage = await _cameraController.takePicture();

          // 이미지 데이터를 Byte 형식으로 변환
          final bytes = await _processCapturedImage(cameraImage);

          if (bytes != null) {
            // 서버로 전송
            _socket.emit('process_image', bytes);
            print("이미지 전송 시도 시간: ${DateTime.now()}");
          } else {
            print("이미지 바이트 변환 실패");
          }
        } catch (e) {
          print("이미지 처리 중 오류 발생: $e");
        } finally {
          _isProcessingFrame = false;
        }
      });

      print("이미지 실시간 스트리밍 시작");
    } catch (e) {
      print("Error during streaming: $e");
      _isStreaming = false;
    }
  }

  void _stopImageStreaming() {
    if (!_isStreaming) return;

    _isStreaming = false;
    _frameTimer?.cancel();
    _frameTimer = null;
    _cameraController.stopImageStream();
    print("이미지 실시간 스트리밍 중단");
  }

  // Uint8List? _convertCameraImageToJPEG(CameraImage cameraImage) {
  //   try {
  //     final int width = cameraImage.width;
  //     final int height = cameraImage.height;
  //
  //     // YUV 데이터를 RGB로 변환
  //     final img.Image rgbImage = img.Image(width, height);
  //
  //     for (int y = 0; y < height; y++) {
  //       for (int x = 0; x < width; x++) {
  //         final int uvIndex = (y ~/ 2) * cameraImage.planes[1].bytesPerRow +
  //             (x ~/ 2) * cameraImage.planes[1].bytesPerPixel!;
  //         final int yIndex = y * cameraImage.planes[0].bytesPerRow + x;
  //
  //         final int yValue = cameraImage.planes[0].bytes[yIndex];
  //         final int uValue = cameraImage.planes[1].bytes[uvIndex];
  //         final int vValue = cameraImage.planes[2].bytes[uvIndex];
  //
  //         final int r = (yValue + 1.402 * (vValue - 128)).clamp(0, 255).toInt();
  //         final int g = (yValue - 0.344 * (uValue - 128) - 0.714 * (vValue - 128))
  //             .clamp(0, 255)
  //             .toInt();
  //         final int b = (yValue + 1.772 * (uValue - 128)).clamp(0, 255).toInt();
  //
  //         rgbImage.setPixel(x, y, img.getColor(r, g, b));
  //       }
  //     }
  //
  //     // 이미지를 90도 회전
  //     final img.Image rotatedImage = img.copyRotate(rgbImage, 270);
  //
  //     // RGB 데이터를 JPEG로 변환
  //     final Uint8List jpegBytes = Uint8List.fromList(img.encodeJpg(rotatedImage, quality: 80));
  //     print("JPEG 데이터 생성 완료: 크기 ${jpegBytes} 바이트");
  //
  //
  //     return jpegBytes;
  //   } catch (e) {
  //     print("Error converting YUV to JPEG: $e");
  //     return null;
  //   }
  // }

  Future<Uint8List?> _processCapturedImage(XFile cameraImage) async {
    try {
      // XFile 데이터를 img.Image 형식으로 변환
      final Uint8List imageBytes = await cameraImage.readAsBytes();
      final img.Image? decodedImage = img.decodeImage(imageBytes);

      if (decodedImage == null) {
        print("이미지 디코딩 실패");
        return null;
      }

      // 이미지를 90도 회전
      final img.Image rotatedImage = img.copyRotate(decodedImage, 270);

      // JPEG로 변환
      final Uint8List jpegBytes =
          Uint8List.fromList(img.encodeJpg(rotatedImage, quality: 80));
      print("JPEG 데이터 생성 완료: 크기 ${jpegBytes.length} 바이트");

      return jpegBytes;
    } catch (e) {
      print("Error processing captured image: $e");
      return null;
    }
  }

  void startStreaming() {
    _startImageStreaming();
  }

  void stopStreaming() {
    _stopImageStreaming();
  }

  void _initStt() async {
    _sttEnabled = await _flutterStt.initialize(
      onStatus: (status) {
        if (status == "listening") {
          if (!_isListening) {
            _isListening = true;
          }
        } else if (status == "notListening") {
          if (_isListening) {
            _isListening = false;
            if (!_isSpeaking && !_isProcessing) {
              Future.delayed(Duration(milliseconds: 500), () {
                _startListening();
              });
            }
          }
        }
      },
      onError: (error) {
        _isListening = false;
        if (!_isSpeaking && !_isProcessing) {
          Future.delayed(Duration(seconds: 1), () {
            _startListening();
          });
        }
      },
    );

    if (_sttEnabled) {
      var systemLocale = await _flutterStt.systemLocale();
      _currentLocaleId = systemLocale?.localeId ?? '';
      print("stt언어 설정: $_currentLocaleId");
      _startListening();
    }
  }

  void _initTts() async {
    await _flutterTts.setLanguage('ko-KR');
    print("TTS 언어가 'ko-KR'로 설정되었습니다.");

    await _flutterTts.setSpeechRate(0.8);
    await _flutterTts.setPitch(1.0);
    await _flutterTts.awaitSpeakCompletion(true);
    _flutterTts.setStartHandler(() {});
    _flutterTts.setCompletionHandler(() {});
    _flutterTts.setErrorHandler((msg) {});
  }

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

  Future<void> _startListening() async {
    if (_sttEnabled && !_isListening && !_isSpeaking && !_isProcessing) {
      //print("Starting STT listening...");
      _isListening = true;
      try {
        await _flutterStt.listen(
          onResult: _onSpeechResult,
          localeId: _currentLocaleId,
          listenFor: Duration(seconds: 30),
          pauseFor: Duration(seconds: 5),
        );
      } catch (e) {
        print("Error during STT listening: $e");
        _isListening = false;
        Future.delayed(Duration(seconds: 1), () {
          _startListening();
        });
      }
    } else {
      // print('STT is not enabled or already listening.');
    }
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    if (result.finalResult) {
      String userInput = result.recognizedWords.trim();
      print("Recognized Final Text: $userInput");

      // 내비게이션 관련 단어/문구 패턴
      List<RegExp> excludedPatterns = [
        RegExp(r'좌회전'),
        RegExp(r'우회전'),
        RegExp(r'직진'),
        RegExp(r'\d+미터 앞에'),
        RegExp(r'목적지'),
        RegExp(r'제한속도'),
        RegExp(r'지하차도'),
        RegExp(r'어린이 보호구역'),
      ];

      // 내비게이션 단어 있으면 무시
      for (RegExp pattern in excludedPatterns) {
        if (pattern.hasMatch(userInput)) {
          print("네비게이션 관련 단어 감지됨, 결과 무시");
          Future.delayed(Duration(seconds: 1), () {
            _startListening();
          });
          return;
        }
      }

      // 여기까지 오면 네비게이션 단어 없음
      _responseWaitTimer?.cancel();
      _awaitingUserResponse = false;
      _retryCount = 0;

      if (!_isProcessing && !_isSpeaking) {
        if (!_isConversationActive && userInput.contains("대화 시작")) {
          _isConversationActive = true;
          _isListening = false;
          _flutterStt.stop();
          _collisionST("대화를 시작합니다. 말씀하세요.");
          Future.delayed(Duration(seconds: 1), () {
            _startListening();
          });
          return;
        }

        if (_isConversationActive) {
          _isListening = false;
          _flutterStt.stop();

          _conversationHistory.add({'role': 'user', 'content': userInput});

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

  Future<void> _collisionST(String text) async {
    print("TTS 함수 호출됨. 출력할 텍스트: $text");

    if (_isListening) {
      await _flutterStt.stop();
      _isListening = false;
      print("STT 중단됨.");
    }
    _isSpeaking = true;

    try {
      List<String> sentences = text.split(RegExp(r'[.?!]'));
      for (String sentence in sentences) {
        sentence = sentence.trim();
        if (sentence.isNotEmpty) {
          String sanitizedText = sentence.replaceAll(
              RegExp(r'[^\u0000-\u007F\uAC00-\uD7A3]+'), '');
          print("TTS에 전달될 텍스트: $sanitizedText");
          await _flutterTts.speak(sanitizedText);
          print("TTS 실행 완료.");
          await _flutterTts.awaitSpeakCompletion(true);
        }
      }
    } catch (e) {
      print("TTS 실행 중 에러 발생: $e");
    } finally {
      _isSpeaking = false;
      Future.delayed(Duration(seconds: 1), () {
        _startListening();
        _startResponseWaitTimer();
      });
    }
  }

  void _startResponseWaitTimer() {
    _responseWaitTimer?.cancel();
    _awaitingUserResponse = true;
    _retryCount++;

    if (_retryCount > _maxRetryCount) {
      _awaitingUserResponse = false;
      _retryCount = 0;
      return;
    }

    List<String> retryMessages = [
      "제가 잘 들을 수 있도록 다시 한번 말해주라?",
      "죄송하지만 못 들었어요. 다시 말해 줄 수 있어?",
      "정신 차려 ! 너 졸고 있는거 아니지?"
    ];

    final random = Random();

    _responseWaitTimer = Timer(Duration(seconds: 10), () {
      if (_awaitingUserResponse) {
        String randomMessage =
            retryMessages[random.nextInt(retryMessages.length)];
        _collisionST(randomMessage);
      }
    });
  }

  Future<String?> generateAnswer() async {
    const String systemPrompt = "너는 운전 중인 사용자의 졸음을 깨우는 데 도움을 주는 챗봇 역할을 하고 있어. "
        "친근한 친구처럼 다정하고 재미있게 대화를 이어가며, 운전자가 졸음을 이겨낼 수 있도록 도와줘. "
        "답변은 항상 간단하고 명확하게 두 문장 이내로 작성하며 사용자를 지칭하거나 '안녕'같은 인사는 하지마, "
        "사용자가 웃거나 대답할 수 있는 질문을 포함해. 예를 들어, '졸리면 안 돼! 내가 재미있는 얘기 하나 해줄까?' 또는 "
        "'지금 주변에 뭐 보여? 바깥 풍경 어때?'와 같이 대화해. 네 목표는 사용자가 깨어 있을 수 있도록 대화를 유도하는 거야. "
        "또한, 답변은 명령조가 아니라 부드럽고 유쾌한 어투를 유지해야 해. "
        "너도 대답은 꼭 하고 질문도 다양하게 생각해봐. 먼저 어떤 것에 흥미가 있는지 물어보고 너의 생각도 말하며 대화를 이어나가면 좋을 것 같아. "
        "요즘 시사나 문제에 대해 토론을 해보는 것도 좋을 것 같아. "
        "좀 신나고 재미있게 해주면 좋을거 같아. 노래도 불러달라고 하면 불러주고 농담도 해주면 좋을거 같아. "
        "차 안에서 할 수 있는 간단한 퀴즈나 게임을 제안해도 좋아. 예를 들어, '지금 주변에 빨간색 물체 몇 개 보여?'처럼 간단한 집중력 게임을 제안해봐. "
        "사용자가 피곤해 보이면 상냥하고 재밌는 방식으로 기분 전환을 유도해봐. "
        "가끔은 사용자가 좋아할만한 흥미로운 잡학 지식이나 가벼운 소식거리를 짧게 던져주는 것도 좋아. "
        "절대 사용자를 비난하거나 공격적인 표현을 쓰지 말고, 항상 응원하고 격려하는 친구 같은 태도를 유지해. "
        "두 문장 이내의 간단한 답변, 그리고 마지막 문장에는 사용자가 대답하거나 반응할 수 있는 질문을 포함하는 것을 잊지마."
        "";

    try {
      print("OPEN AI API 호출 시작");

      final response = await OpenAI.instance.chat.create(
        model: "gpt-3.5-turbo",
        messages: [
          OpenAIChatCompletionChoiceMessageModel(
            role: OpenAIChatMessageRole.system,
            content: [
              OpenAIChatCompletionChoiceMessageContentItemModel.text(
                  systemPrompt)
            ],
          ),
          ..._conversationHistory.map((message) {
            return OpenAIChatCompletionChoiceMessageModel(
              role: message['role'] == 'user'
                  ? OpenAIChatMessageRole.user
                  : OpenAIChatMessageRole.assistant,
              content: [
                OpenAIChatCompletionChoiceMessageContentItemModel.text(
                    message['content']!)
              ],
            );
          }).toList(),
        ],
        maxTokens: 100,
      );

      String? gptResponse = response.choices.first.message.content?.first.text;
      print("OpenAI API 응답: $gptResponse");
      return gptResponse;
    } catch (e, stackTrace) {
      print("OpenAI API 호출 중 에러 발생: $e");
      print("스택 트레이스: $stackTrace");
      _isProcessing = false;

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
