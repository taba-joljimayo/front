import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sleepy/screens/screen_camera.dart';
import 'package:camera/camera.dart';
import 'package:video_player/video_player.dart';

class LoadingScreen extends StatefulWidget {
  final CameraDescription camera;

  const LoadingScreen({required this.camera});

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen> {
  late VideoPlayerController _videoController;

  @override
  void initState() {
    super.initState();

    // 동영상 컨트롤러 초기화
    _videoController = VideoPlayerController.asset('assets/eye_mouth.mp4')
      ..initialize().then((_) {
        // 동영상이 준비되면 실행
        setState(() {});
        _videoController.play();
      });

    Timer(Duration(milliseconds: 3000), () {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => CameraScreen(camera: widget.camera),
        ),
      );
    });
  }

  @override
  void dispose() {
    _videoController.dispose(); // 동영상 컨트롤러 해제
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
                padding: EdgeInsets.fromLTRB(10, 0, 10, 0),
                child: AspectRatio(
                  aspectRatio: _videoController.value.aspectRatio,
                  child: VideoPlayer(_videoController),
                )),
            SizedBox(height: 90),
            Text(
              '졸지마요',
              style: TextStyle(
                fontFamily: 'school',
                fontWeight: FontWeight.w700,
                fontSize: 60,
                letterSpacing: 2,
              ),
            )
          ],
        ),
      ),
    );
  }
}
