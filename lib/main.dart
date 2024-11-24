import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:sleepy/screens/screen_camera.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

void main() async {
  // 플러그인 서비스 초기화 확인
  WidgetsFlutterBinding.ensureInitialized();
  // 장치의 카메라 리스드 얻어옴
  final cameras = await availableCameras();
  // 리스트 중 전면 카메라
  final frontCamera = cameras.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.front
  );

  await dotenv.load(fileName: ".env");


  runApp(MyApp(camera: frontCamera));
}

class MyApp extends StatelessWidget {
  final CameraDescription camera;

  MyApp({required this.camera});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: CameraScreen(camera: camera),
    );
  }
}


