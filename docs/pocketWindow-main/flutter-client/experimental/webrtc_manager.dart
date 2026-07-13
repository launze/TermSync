// 完整的 WebRTC 管理服务
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:pocketwindow/services/signaling_service.dart';

enum ConnectionState { idle, connecting, connected, failed }

class WebRTCManager {
  final SignalingService _signaling;
  RTCPeerConnection? _peerConnection;
  RTCMediaStream? _localStream;
  RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  ConnectionState _state = ConnectionState.idle;
  ConnectionState get state => _state;

  WebRTCManager(String signalingUrl, String roomId)
      : _signaling = SignalingService(serverUrl: signalingUrl, roomId: roomId) {
    _initPeerConnection();
    _setupSignalingCallbacks();
  }

  /// 初始化 PeerConnection
  void _initPeerConnection() async {
    final configuration = {
      'iceServers': [
        {'urls': ['stun:stun.l.google.com:19302']},
        {'urls': ['stun:stun1.l.google.com:19302']},
      ]
    };

    _peerConnection = await RTCPeerConnectionFactory.instance
        .createPeerConnection(configuration);

    _peerConnection?.onIceCandidate = (RTCIceCandidate? candidate) {
      if (candidate != null) {
        _signaling.sendIceCandidate({
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      }
    };

    _peerConnection?.onIceConnectionState =
        (RTCIceConnectionState state) {
      print('Ice connection state: $state');

      if (state == RTCIceConnectionState.completed) {
        _setState(ConnectionState.connected);
      } else if (state == RTCIceConnectionState.failed) {
        _setState(ConnectionState.failed);
      }
    };

    _peerConnection?.onAddStream = (RTCMediaStream? stream) {
      print('Received remote stream');
      _remoteRenderer.srcObject = stream;
    };
  }

  /// 设置信令回调
  void _setupSignalingCallbacks() {
    _signaling.onStatus = (status) {
      print('[Signaling] $status');
      if (status.contains('远程端已连接')) {
        _createAnswer();
      }
    };

    _signaling.onOffer = (data) async {
      print('[Signaling] Received offer');
      await _setRemoteDescription(data['offer']);
      await _createAnswer();
    };

    _signaling.onAnswer = (data) async {
      print('[Signaling] Received answer');
      await _setRemoteDescription(data['answer']);
    };

    _signaling.onIceCandidate = (data) {
      final candidate = RTCIceCandidate(
        candidate: data['candidate']['candidate'],
        sdpMid: data['candidate']['sdpMid'],
        sdpMLineIndex: data['candidate']['sdpMLineIndex'],
      );
      _peerConnection?.addCandidate(candidate);
    };
  }

  /// 连接到信令服务器
  void connect() {
    _setState(ConnectionState.connecting);
    _signaling.connect();
  }

  /// 创建 Offer 并发送
  Future<void> createOffer() async {
    if (_peerConnection == null) return;

    final RTCSessionDescription offer =
        await _peerConnection!.createOffer({'offerToReceiveVideo': true});
    await _peerConnection!.setLocalDescription(offer);
    _signaling.sendOffer(offer.sdp);
  }

  /// 设置远程描述
  Future<void> _setRemoteDescription(String sdp) async {
    if (_peerConnection == null) return;

    final description = RTCSessionDescription(sdp, 'answer');
    await _peerConnection!.setRemoteDescription(description);
  }

  /// 创建 Answer
  Future<void> _createAnswer() async {
    if (_peerConnection == null) return;

    final RTCSessionDescription answer =
        await _peerConnection!.createAnswer({'offerToReceiveVideo': true});
    await _peerConnection!.setLocalDescription(answer);
    _signaling.sendAnswer(answer.sdp);
  }

  /// 设置远程视频渲染器
  void setRemoteRenderer(RTCVideoRenderer renderer) {
    _remoteRenderer = renderer;
  }

  /// 关闭连接
  Future<void> close() async {
    _peerConnection?.close();
    _signaling.disconnect();
    _remoteRenderer.dispose();
    _setState(ConnectionState.idle);
  }

  void _setState(ConnectionState newState) {
    _state = newState;
  }
}
