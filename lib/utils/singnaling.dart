import 'dart:convert';
import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webrtc_player/utils/websocket.dart';

enum SignalingState {
  ConnectionOpen,
  ConnectionClosed,
}

enum VideoState {
  VideoStreamConnecting,
  VideoStreamConnected,
}

class Session {
  Session({required this.sid, required this.pid});

  String pid;
  String sid;
  RTCPeerConnection? pc;
  RTCDataChannel? dc;
  List<RTCIceCandidate> remoteCandidates = [];
}

class Signaling {
  Signaling();

  JsonDecoder _decoder = JsonDecoder();
  SimpleWebSocket? _socket;
  Map<String, Session> _sessions = {};

  List<MediaStream> _remoteStreams = <MediaStream>[];
  Function(RTCPeerConnectionState state)? onRTCPeerConnectionStateChange;
  Function(SignalingState state)? onSignalingStateChange;
  Function(Session session, VideoState state)? onCallStateChange;
  Function(MediaStream stream)? onLocalStream;
  Function(Session session, MediaStream stream)? onAddRemoteStream;
  Function(Session session, MediaStream stream)? onRemoveRemoteStream;
  Function(dynamic event)? onPeersUpdate;
  Function(Session session, RTCDataChannel dc, RTCDataChannelMessage data)?
      onDataChannelMessage;
  Function(Session session, RTCDataChannel dc)? onDataChannel;
  Function(Map<dynamic, dynamic>)? onInfoVideo;
  String _url = '';

  String get sdpSemantics =>
      WebRTC.platformIsWindows ? 'plan-b' : 'unified-plan';

  Map<String, dynamic> _iceServers = {};

  final Map<String, dynamic> _config = {
    'mandatory': {},
    'optional': [
      {'DtlsSrtpKeyAgreement': true},
    ]
  };

  final Map<String, dynamic> _dcConstraints = {
    'mandatory': {
      'OfferToReceiveAudio': true,
      'OfferToReceiveVideo': true,
    },
    'optional': [],
  };
  List<dynamic> _candidates = [];

  close() async {
    await _cleanSessions();
    _socket?.close();
  }

  void onMessage(message) async {
    Map<String, dynamic> data = message;

    switch (data['command']) {
      case 'offer':
        {
          var peerId = data['peer_id'].toString();
          var description = data['sdp'];
          var media = 'video';
          var sessionId = data['id'].toString();
          var session = _sessions[sessionId];

          _iceServers = {'iceServers': data['iceServers']};

          var newSession = await _createSession(session,
              peerId: peerId,
              sessionId: sessionId,
              media: media,
              screenSharing: false);
          _sessions[sessionId] = newSession;
          await newSession.pc?.setRemoteDescription(
              RTCSessionDescription(description['sdp'], description['type']));
          await _createAnswer(newSession, 'data');

          _candidates = data['candidates'];
          for (int i = 0; i < _candidates.length; i++) {
            newSession.remoteCandidates.add(RTCIceCandidate(
                _candidates[i]['candidate'],
                '',
                _candidates[i]['sdpMLineIndex']));
          }
          _candidates.clear();
          if (newSession.remoteCandidates.isNotEmpty) {
            newSession.remoteCandidates.forEach((candidate) {
              newSession.pc?.addCandidate(candidate);
            });
            newSession.remoteCandidates.clear();
          }
          onCallStateChange?.call(newSession, VideoState.VideoStreamConnected);
        }
        break;
      case 'notification':
        Map? result = data['message'];
        if (result != null) {
          if (result['renditions'] != null) {
            result = result['renditions'][0];
          }
        }

        if (result != null) {
          result = result['video_track'];
        }

        if (result != null) {
          result = result['video'];
        }
        if (result != null) {
          onInfoVideo?.call(result);
        }

        break;
      case 'ping':
        _send({"command": 'pong'});
        break;
      default:
        break;
    }
  }

  Future<void> connect(String url) async {
    // url = 'wss://live83d245.dev.tmtco.org:3334/liveapp/hau123456';`
    if (url.contains('wss://')) {
      url = url.replaceFirst('wss://', 'https://');
    }

    _socket = SimpleWebSocket(url);
    _url = url;
    print('connect to $url');

    _socket?.onOpen = () {
      print('onOpen');
      onSignalingStateChange?.call(SignalingState.ConnectionOpen);
      _send({'command': 'request_offer'});
    };

    _socket?.onMessage = (message) {
      print('Received data: ' + message);
      onMessage(_decoder.convert(message));
    };

    _socket?.onClose = (int? code, String? reason) {
      print('Closed by server [$code => $reason]!');
      onSignalingStateChange?.call(SignalingState.ConnectionClosed);
    };

    await _socket?.connect();
  }

  Future<Session> _createSession(Session? session,
      {required String peerId,
      required String sessionId,
      required String media,
      required bool screenSharing}) async {
    var newSession = session ?? Session(sid: sessionId, pid: peerId);

    print('_iceServers: ..................$_iceServers');
    RTCPeerConnection pc = await createPeerConnection({
      ..._iceServers,
      ...{'sdpSemantics': sdpSemantics}
    }, _config);
    if (media != 'data') {
      switch (sdpSemantics) {
        case 'plan-b':
          pc.onAddStream = (MediaStream stream) {
            onAddRemoteStream?.call(newSession, stream);
            _remoteStreams.add(stream);
          };

          break;
        case 'unified-plan':
          // Unified-Plan
          pc.onTrack = (event) {
            if (event.track.kind == 'video') {
              onAddRemoteStream?.call(newSession, event.streams[0]);
              onCallStateChange?.call(
                  newSession, VideoState.VideoStreamConnected);
            }
          };

          break;
      }
    }
    pc.onConnectionState = (state) async {
      onRTCPeerConnectionStateChange?.call(state);
    };
    pc.onIceCandidate = (candidate) async {
      // This delay is needed to allow enough time to try an ICE candidate
      // before skipping to the next one. 1 second is just an heuristic value
      // and should be thoroughly tested in your own environment.

      await Future.delayed(
          const Duration(seconds: 1),
          () => _send({
                'command': 'candidate',
                'candidates': [candidate.toMap()],
                "peer_id": peerId,
                'id': int.parse(sessionId),
              }));
    };

    pc.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        pc.restartIce();
        connect(_url);
      }
    };

    pc.onRemoveStream = (stream) {
      onRemoveRemoteStream?.call(newSession, stream);
      _remoteStreams.removeWhere((it) {
        return (it.id == stream.id);
      });
    };

    pc.onDataChannel = (channel) {
      _addDataChannel(newSession, channel);
    };

    newSession.pc = pc;

    return newSession;
  }

  void _addDataChannel(Session session, RTCDataChannel channel) {
    channel.onDataChannelState = (e) {};
    channel.onMessage = (RTCDataChannelMessage data) {
      onDataChannelMessage?.call(session, channel, data);
    };
    session.dc = channel;
    onDataChannel?.call(session, channel);
  }

  Future<void> _createAnswer(Session session, String media) async {
    try {
      RTCSessionDescription s =
          await session.pc!.createAnswer(media == 'data' ? _dcConstraints : {});
      await session.pc!.setLocalDescription(s);
      _send({
        'id': int.parse(session.sid),
        'command': 'answer',
        "peer_id": "0",
        // 'candidates': _candidates,
        'sdp': {'sdp': s.sdp, 'type': s.type},
      });
    } catch (e) {
      print('_createAnswer$e');
    }
  }

  _send(Map map) {
    _socket?.send(jsonEncode(map));
  }

  Future<void> _cleanSessions() async {
    _sessions.forEach((key, sess) async {
      await sess.pc?.close();
      await sess.dc?.close();
    });
    _sessions.clear();
  }
}
