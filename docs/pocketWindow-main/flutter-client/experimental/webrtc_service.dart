import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRTCService {
  final _peerConnectionFactory = RTCPeerConnectionFactory.instance;
  RTCPeerConnection? _peerConnection;
  RTCMediaStream? _mediaStream;
  bool _connected = false;

  // 信令服务器地址
  final String _signalingUrl;
  final String _roomId;

  WebRTCService({
    String signalingUrl = 'ws://localhost:58080',
    String roomId = '',
  })  : _signalingUrl = signalingUrl,
        _roomId = roomId;

  bool get isConnected => _connected;

  /// 创建 PeerConnection
  Future<void> createPeerConnection() async {
    final configuration = {
      'iceServers': [
        {'urls': ['stun:stun.l.google.com:19302']},
        {'urls': ['stun:stun1.l.google.com:19302']},
      ]
    };

    _peerConnection = await _peerConnectionFactory.createPeerConnection(configuration);

    _peerConnection?.onIceCandidate = (RTCIceCandidate? candidate) {
      if (candidate != null) {
        _sendIceCandidate(candidate);
      }
    };

    _peerConnection?.onIceConnectionState = (RTCIceConnectionState state) {
      print('Ice connection state: $state');
      if (state == RTCIceConnectionState.completed) {
        _connected = true;
      }
    };

    _peerConnection?.onAddStream = (RTCMediaStream stream) {
      print('Received media stream');
      _mediaStream = stream;
    };
  }

  /// 创建并发送 Offer
  Future<void> createOffer() async {
    if (_peerConnection == null) return;

    final RTCSessionDescription offer =
        await _peerConnection!.createOffer({'offerToReceiveVideo': true});

    await _peerConnection!.setLocalDescription(offer);

    // 发送 Offer 到信令服务器
    _sendOffer(offer);
  }

  /// 设置远程描述（Answer）
  Future<void> setRemoteDescription(String sdp) async {
    final RTCSessionDescription description =
        RTCSessionDescription(sdp, 'answer');
    await _peerConnection!.setRemoteDescription(description);
  }

  /// 发送 ICE 候选
  void _sendIceCandidate(RTCIceCandidate candidate) {
    final message = {
      'type': 'ice_candidate',
      'room_id': _roomId,
      'candidate': {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      }
    };
    // 通过 WebSocket 发送
    // _socket!.emit('send_ice_candidate', message);
  }

  /// 发送 Offer
  void _sendOffer(RTCSessionDescription offer) {
    final message = {
      'type': 'offer',
      'room_id': _roomId,
      'offer': offer.sdp,
      'role': 'client'
    };
    // 通过 WebSocket 发送
    // _socket!.emit('send_offer', message);
  }

  /// 关闭连接
  Future<void> close() async {
    _connected = false;
    await _peerConnection?.close();
    _peerConnection = null;
  }
}
