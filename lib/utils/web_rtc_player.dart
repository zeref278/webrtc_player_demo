import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webrtc_player/utils/singnaling.dart';

class WebRTCPlayer extends StatefulWidget {
  const WebRTCPlayer({
    this.url,
    this.thumbnailUrl,
    this.isPlayingEnable = true,
  });

  final String? url;
  final String? thumbnailUrl;
  final bool isPlayingEnable;

  @override
  _WebRTCPlayerState createState() => _WebRTCPlayerState();
}

class _WebRTCPlayerState extends State<WebRTCPlayer> {
  _WebRTCPlayerState();

  Signaling? _signaling;
  RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _isPlaying = false;

  // bool _isDisconnect = false;
  double _videoHeight = 0;
  double _videoWidth = 0;
  RTCPeerConnectionState? _connectionState;

  @override
  initState() {
    // if (widget.isPlayingEnable == false) {
    initRenderers();
      _connect();
    // }
    super.initState();
  }

  initRenderers() async {
    await _remoteRenderer.initialize();
  }

  @override
  void deactivate() {
    _signaling?.close();
    _remoteRenderer.dispose();
    super.deactivate();
  }

  void _connect() async {
    _signaling ??= Signaling()..connect(widget.url ?? '');
    _signaling?.onSignalingStateChange = (SignalingState state) {
      switch (state) {
        case SignalingState.ConnectionClosed:

        case SignalingState.ConnectionOpen:
          break;
      }
    };

    _signaling?.onCallStateChange = (Session session, VideoState state) async {
      switch (state) {
        case VideoState.VideoStreamConnected:
          _isPlaying = true;
          setState(() {});

          break;
        case VideoState.VideoStreamConnecting:
          _isPlaying = false;
          setState(() {});
      }
    };
    _signaling?.onRTCPeerConnectionStateChange = (state) {
      _connectionState = state;
      if (_connectionState ==
          RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _isPlaying = true;
        setState(() {});
      }
      if (_connectionState ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _isPlaying = false;
        setState(() {});
      }
    };

    _signaling?.onAddRemoteStream = ((_, stream) async {
      _remoteRenderer.srcObject = stream;
      setState(() {});
    });

    _signaling?.onRemoveRemoteStream = ((_, stream) {
      _remoteRenderer.srcObject = null;
      setState(() {});
    });
    _signaling?.onInfoVideo = (data) {
      if (data['height'] != null) {
        _videoHeight = data['height']?.toDouble();
      }
      if (data['width'] != null) {
        _videoWidth = data['width']?.toDouble();
      }

      setState(() {});
    };
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        if (widget.isPlayingEnable) {
          _isPlaying = !_isPlaying;

          if (_isPlaying) {
            initRenderers();
            _connect();
          } else {
            _signaling?.close();
            _signaling = null;
          }
          setState(() {});
        }
      },
      child: OrientationBuilder(builder: (context, orientation) {
        return Stack(
          children: [
            Positioned(
              left: 0.0,
              right: 0.0,
              top: 0.0,
              bottom: 0.0,
              child: Container(
                margin: const EdgeInsets.fromLTRB(0.0, 0.0, 0.0, 0.0),
                width: MediaQuery.of(context).size.width,
                height: MediaQuery.of(context).size.height,
                decoration: const BoxDecoration(color: Colors.black54),
                child: _buildVideo(),
              ),
            ),
            if (!_isPlaying && widget.isPlayingEnable)
              const CircularProgressIndicator(),
          ],
        );
      }),
    );
  }

  Widget _buildVideo() {
    if (_connectionState ==
        RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      return Padding(
        padding: EdgeInsets.only(
            bottom: (_videoWidth / _videoHeight == 16 / 9 &&
                    widget.isPlayingEnable == false)
                ? MediaQuery.of(context).size.height / 2 - 62
                : 0),
        child: Stack(
          children: [
            RTCVideoView(_remoteRenderer, filterQuality: FilterQuality.low),
            if (_connectionState ==
                    RTCPeerConnectionState.RTCPeerConnectionStateDisconnected &&
                widget.isPlayingEnable == false)
              const CircularProgressIndicator(),
          ],
        ),
      );
    }

    return Container(
      height: double.infinity,
      width: double.infinity,
      child: Image.network(
        widget.thumbnailUrl ?? "",
        errorBuilder: (
          BuildContext context,
          Object error,
          StackTrace? stackTrace,
        ) {
          return const SizedBox();
        },
      ),
    );
  }
}
