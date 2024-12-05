import 'dart:async';
import 'dart:convert';
import 'dart:math';

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
// 소켓 수정
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

  // 소켓 추가
  late io.Socket _socket;

  final SpeechToText _flutterStt = SpeechToText();
  final FlutterTts _flutterTts = FlutterTts();

  bool _sttEnabled = false;
  bool _isListening = false; // STT 활성 상태
  bool _isSpeaking = false; // TTS 활성 상태
  bool _isProcessing = false; // API 호출 중 상태
  bool _isConversationActive = false; // 대화 상태

  bool _isStreaming = false; // 실시간 전송 상태
  //Timer? _streamTimer; // 실시간 전송용 타이머
  Timer? _frameTimer;
  bool _isProcessingFrame = false; // 현재 프레임 처리 중인지 확인

  String _currentLocaleId = '';

  List<Map<String, String>> _conversationHistory = []; // 대화 히스토리

  // 추가된 상태 변수
  Timer? _responseWaitTimer; // 사용자 응답 대기 타이머
  bool _awaitingUserResponse = false; // 사용자 응답 대기 상태
  int _retryCount = 0;
  int _maxRetryCount = 3;

/*
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
        //cancelOnError: false, // 에러 발생 시 스트림이 닫히지 않도록 설정
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
    _responseWaitTimer?.cancel(); // 타이머 취소
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
  }*/
  // 기존 수정 socket.io로 변경
  @override
  void initState() {
    super.initState();
    _cameraController = CameraController(
      widget.camera,
      ResolutionPreset.high,
    );
    _initializeControllerFuture = _cameraController.initialize();

    // Socket.io 초기화
    _socket = io.io('http://192.168.0.15:5000', <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
    });

    // 서버 연결 이벤트
    _socket.onConnect((_) {
      print('Socket.IO 서버에 연결되었습니다.');
    });

    // 서버로부터 데이터 수신
    _socket.on('result', (data) {
      print("서버로부터 데이터 수신: $data");
      // 수신된 데이터를 처리 (예: 상태를 업데이트)
      if (data is Map && data['status'] == 'success') {
        final int result = data['result'];
        print(result == 1 ? "두 눈 감음" : "두 눈 뜸");
      } else {
        print("에러 메시지: ${data['message']}");
      }
    });

    // 에러 및 연결 종료 이벤트 처리
    _socket.onError((error) {
      print("Socket.IO 에러: $error");
    });

    _socket.onDisconnect((_) {
      print("Socket.IO 연결 종료");
    });

    _initStt();
    _initTts();
    _initOpenAI();
  }

  @override
  void dispose() {
    _cameraController.dispose();
    _socket.disconnect();
    super.dispose();
  }

  Future<void> _startImageStreaming() async {
    if (_isStreaming) return;

    try {
      await _initializeControllerFuture;

      _isStreaming = true;
      _cameraController.startImageStream((CameraImage cameraImage) {
        if (!_isStreaming || _isProcessingFrame) return;
        // 프레임 처리 주기 설정 (초당 10프레임 = 100ms)
        _frameTimer ??=
            Timer.periodic(Duration(milliseconds: 100), (timer) async {
          if (!_isStreaming) {
            timer.cancel();
            return;
          }

          _isProcessingFrame = true;

          // 이미지 데이터를 raw bytes로 변환
          final bytes = _convertCameraImageToRawBytes(cameraImage);

          // 서버로 전송
          if (bytes != null) {
            _socket.emit('process_image', bytes);
            print("이미지 바이너리 데이터 전송 완료");
          }

          _isProcessingFrame = false;
        });
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

    // 타이머 중지
    _frameTimer?.cancel();
    _frameTimer = null;

    _cameraController.stopImageStream();
    print("이미지 실시간 스트리밍 중단");
  }

  Uint8List? _convertCameraImageToRawBytes(CameraImage cameraImage) {
    try {
      // YUV 포맷을 JPEG로 변환 (최적화 가능)
      final bytes = Uint8List.fromList(cameraImage.planes[0].bytes);
      return bytes;
    } catch (e) {
      print("Error converting image: $e");
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

  // 음성 인식 시작
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

  // 음성 인식 결과 처리
  void _onSpeechResult(SpeechRecognitionResult result) {
    if (result.finalResult) {
      String userInput = result.recognizedWords.trim();
      print("Recognized Final Text: $userInput");

      // 정규표현식 패턴 목록
      List<RegExp> excludedPatterns = [
        RegExp(r'좌회전'),
        RegExp(r'우회전'),
        RegExp(r'직진'),
        RegExp(r'\d+미터 앞에'), // 숫자+미터 앞에서
        RegExp(r'목적지'),
        RegExp(r'제한속도'),
        RegExp(r'지하차도'),
        RegExp(r'어린이보호구역'),
        // 추가 패턴
      ];

      // 제외할 패턴을 제거
      for (RegExp pattern in excludedPatterns) {
        userInput = userInput.replaceAll(pattern, '');
      }

      // 공백 제거 후, 남은 텍스트가 있는지 확인
      userInput = userInput.trim();

      if (userInput.isEmpty) {
        print("제외할 단어만 포함되어 있어 결과를 무시합니다.");
        // STT 재시작 또는 필요한 처리를 합니다.
        return;
      }

      // 사용자가 응답했으므로 응답 대기 타이머 취소
      _responseWaitTimer?.cancel();
      _awaitingUserResponse = false;
      _retryCount = 0;

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
      // 텍스트를 문장 단위로 분할
      List<String> sentences = text.split(RegExp(r'[.?!]'));
      for (String sentence in sentences) {
        sentence = sentence.trim();
        if (sentence.isNotEmpty) {
          // 텍스트에서 이모지나 특수문자 제거
          String sanitizedText = sentence.replaceAll(
              RegExp(r'[^\u0000-\u007F\uAC00-\uD7A3]+'), '');
          print("TTS에 전달될 텍스트: $sanitizedText");
          await _flutterTts.speak(sanitizedText);
          print("TTS 실행 완료.");
          // 각 문장의 발화를 기다림
          await _flutterTts.awaitSpeakCompletion(true);
        }
      }
    } catch (e) {
      print("TTS 실행 중 에러 발생: $e");
    } finally {
      _isSpeaking = false; // TTS 완료 또는 실패 시

      // TTS가 완료되었으므로 STT 재시작
      Future.delayed(Duration(seconds: 1), () {
        _startListening();

        // 사용자 응답 대기 타이머 시작
        _startResponseWaitTimer();
      });
    }
  }

  void _startResponseWaitTimer() {
    // 기존 타이머가 있다면 취소
    _responseWaitTimer?.cancel();
    _awaitingUserResponse = true;
    _retryCount++;

    if (_retryCount > _maxRetryCount) {
      _awaitingUserResponse = false;
      _retryCount = 0;
      return;
    }

    // 예시 문구 리스트 생성
    List<String> retryMessages = [
      "제가 잘 들을 수 있도록 다시 한번 말해주라?",
      "죄송하지만 못 들었어요. 다시 말해 줄 수 있어?",
      "정신 차려 ! 너 졸고 있는거 아니지?"
    ];

    // Random 객체 생성
    final random = Random();

    // 응답 대기 타이머 시작 (예: 5초)
    _responseWaitTimer = Timer(Duration(seconds: 5), () {
      if (_awaitingUserResponse) {
        // 랜덤으로 문구 선택
        String randomMessage =
            retryMessages[random.nextInt(retryMessages.length)];

        // 사용자가 응답하지 않았으므로 다시 질문
        _collisionST(randomMessage);
      }
    });
  }

  // GPT 응답 생성
  Future<String?> generateAnswer() async {
    const String systemPrompt = "너는 운전 중인 사용자의 졸음을 깨우는 데 도움을 주는 챗봇 역할을 하고 있어. "
        "친근한 친구처럼 다정하고 재미있게 대화를 이어가며, 운전자가 졸음을 이겨낼 수 있도록 도와줘. "
        "답변은 항상 간단하고 명확하게 두 문장 이내로 작성하며 사용자를 지칭하거나 '안녕'같은 인사는 하지마, "
        "사용자가 웃거나 대답할 수 있는 질문을 포함해. 예를 들어, '졸리면 안 돼! 내가 재미있는 얘기 하나 해줄까?' 또는 "
        "'지금 주변에 뭐 보여? 바깥 풍경 어때?'와 같이 대화해. 네 목표는 사용자가 깨어 있을 수 있도록 대화를 유도하는 거야. "
        "또한, 답변은 명령조가 아니라 부드럽고 유쾌한 어투를 유지해야 해. "
        "너도 대답은 꼭 하고 질문도 다양하게 생각해봐. 먼저 어떤 것에 흥미가 있는지 물어보고 너의 생각도 말하며 대화를 이어나가면 좋을 것 같아. "
        "요즘 시사나 문제에 대해 토론을 해보는 것도 좋을 것 같아."
        "좀 신나고 재미있게 해주면 좋을거 같아. 노래도 불러달라고 하면 불러주고 농담도 해주면 좋을거 같아. ";

    try {
      print("OPEN AI API 호출 시작");

      final response = await OpenAI.instance.chat.create(
        model: "gpt-4o-mini", // 모델 이름 수정
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
      _isProcessing = false; // 상태 변수 업데이트

      // 예외 발생 시 STT 재시작
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
