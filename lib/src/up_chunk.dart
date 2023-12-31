import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:mime/mime.dart';

import 'package:flutter_upchunk/src/connection_status_singleton.dart';
import 'package:flutter_upchunk/src/up_chunk_options.dart';

class UpChunk {
  /// HTTP response codes implying the PUT method has been successful
  final successfulChunkUploadCodes = const [200, 201, 202, 204, 308];

  /// HTTP response codes implying a chunk may be retried
  final temporaryErrorCodes = const [408, 502, 503, 504];

  List<String>? endPoints;
  Future<String>? endPointResolver;
  File? file;
  List<Interceptor> interceptors = [];
  Map<String, String> headers = {};
  int chunkSize = 0;
  int startChunk = 0;
  int attempts = 0;
  int delayBeforeAttempt = 0;

  Stream<List<int>> _chunk = Stream.empty();
  int _chunkLength = 0;
  int _fileSize = 0;
  int _chunkCount = 0;
  int _chunkByteSize = 0;
  String? _fileMimeType;
  Uri _endpointValue = Uri();
  int _totalChunks = 0;
  int _attemptCount = 0;
  bool _offline = false;
  bool _paused = false;
  bool _stopped = false;

  CancelToken? _currentCancelToken;

  bool _uploadFailed = false;

  void Function()? _onOnline;
  void Function()? _onOffline;
  void Function(Map<String, dynamic>)? _onChunkUploaded;
  void Function(int chunkNumber, int chunkSize)? _onAttempt;
  void Function(String message, int chunkNumber, int attemptsLeft)? _onAttemptFailure;
  void Function(String message, int chunk, int attempts)? _onError;
  void Function()? _onSuccess;
  void Function(double progress, int chunk)? _onProgress;

  static UpChunk createUpload(UpChunkOptions options) => UpChunk._internal(options);

  /// Internal constructor used by [createUpload]
  UpChunk._internal(UpChunkOptions options) {
    endPoints = options.endPoint;
    endPointResolver = options.endPointResolver;
    file = options.file;
    headers = options.headers;
    chunkSize = options.chunkSize;
    startChunk = options.startChunk ?? 0;
    attempts = options.attempts;
    delayBeforeAttempt = options.delayBeforeAttempt;
    interceptors = options.interceptors;

    _validateOptions();

    _chunkCount += startChunk;
    _onOnline = options.onOnline;
    _onOffline = options.onOffline;
    _onAttempt = options.onAttempt;
    _onAttemptFailure = options.onAttemptFailure;
    _onError = options.onError;
    _onSuccess = options.onSuccess;
    _onProgress = options.onProgress;
    _onChunkUploaded = options.onChunkUploaded;

    _getEndpoint().then((value) async {
      _fileSize = await options.file!.length();

      _chunkByteSize = (_fileSize / endPoints!.length).ceil();

      _totalChunks = endPoints!.length;

      _getMimeType();
    }).then((_) => _sendChunks());

    // restart sync when back online
    // trigger events when offline / back online
    ConnectionStatusSingleton connectionStatus = ConnectionStatusSingleton.getInstance();
    connectionStatus.connectionChange.listen(_connectionChanged);
  }

  /// It pauses the upload, the [_chunk] currently being uploaded will finish first before pausing the next [_chunk]
  void pause() => _paused = true;

  /// It resumes the upload for the next [_chunk]
  void resume() {
    if (!_paused) return;

    _paused = false;
    _sendChunks();
  }

  void stop() {
    _stopped = true;
    _uploadFailed = true;
    _currentCancelToken!.cancel(Exception('Upload cancelled by the user'));

    if (_onError != null)
      _onError!(
        'Upload cancelled by the user.',
        _chunkCount,
        _attemptCount,
      );
  }

  /// It gets [file]'s mime type, if possible
  void _getMimeType() async {
    try {
      _fileMimeType = lookupMimeType(file!.path);
    } catch (_) {
      _fileMimeType = null;
    }
  }

  /// It validates the passed options
  void _validateOptions() {
    if (startChunk < 0) throw ArgumentError('startChunk must be greater than or equal to 0');

    if (endPoints == null && endPointResolver == null)
      throw new Exception('either endPoint or endPointResolver must be defined');

    if (file == null) throw new Exception('file can' 't be null');

    if (chunkSize <= 0 || chunkSize % 64 != 0)
      throw new Exception('chunkSize must be a positive number in multiples of 64');

    if (attempts <= 0) throw new Exception('retries must be a positive number');

    if (delayBeforeAttempt < 0) throw new Exception('delayBeforeAttempt must be a positive number');
  }

  /// Gets a value for [_endpointValue]
  ///
  /// If [endPoints] is provided it converts it to a Uri and returns the value,
  /// otherwise it uses [endPointResolver] to resolve the Uri value to return
  Future<Uri> _getEndpoint() async {
    if (endPoints != null) {
      _endpointValue = Uri.parse(endPoints![_chunkCount]);
      return _endpointValue;
    }

    endPoints = [await endPointResolver!];
    _endpointValue = Uri.parse(endPoints![_chunkCount]);
    return _endpointValue;
  }

  /// Callback for [ConnectionStatusSingleton] to notify connection changes
  ///
  /// if the connection drops [_offline] is marked as true and upload us paused,
  /// if connection is restore [_offline] is marked as false and resumes the upload
  void _connectionChanged(dynamic hasConnection) {
    if (hasConnection) {
      if (!_offline) return;

      _offline = false;

      if (_onOnline != null) _onOnline!();

      _sendChunks();
    }

    if (!hasConnection) {
      _offline = true;

      if (_onOffline != null) _onOffline!();
    }
  }

  /// Sends [_chunk] of the file with appropriate headers
  Future<Response> _sendChunk() async {
    // add chunk request headers
    var rangeStart = _chunkCount * _chunkByteSize;
    var rangeEnd = rangeStart + _chunkLength - 1;

    print(_chunkLength);

    print( _fileSize);

    Map<String, dynamic> putHeaders = {
      'content-range': 'bytes $rangeStart-$rangeEnd/$_fileSize',
      Headers.contentLengthHeader: _chunkLength
    };
    if (_fileMimeType != null) {
      putHeaders.putIfAbsent(Headers.contentTypeHeader, () => _fileMimeType!);
    }
    headers.forEach((key, value) => putHeaders.putIfAbsent(key, () => value));

    if (_onAttempt != null)
      _onAttempt!(
        _chunkCount,
        _chunkLength,
      );

    _currentCancelToken = CancelToken();

    final dio = Dio()..interceptors.addAll(interceptors);

    // returns future with http response
    return dio.putUri(
      _endpointValue,
      options: Options(
        headers: putHeaders,
        followRedirects: false,
        validateStatus: (status) => true,
      ),
      data: _chunk,
      onSendProgress: (int sent, int total) {
        if (_onProgress != null) {
          final bytesSent = _chunkCount * _chunkByteSize;
          final percentProgress = (bytesSent + sent) * 100.0 / _fileSize;

          if (percentProgress < 100.0) _onProgress!(percentProgress, _chunkCount);
        }
      },
      cancelToken: _currentCancelToken,
    );
  }

  /// Gets [_chunk] and [_chunkLength] for the portion of the file of x bytes corresponding to [_chunkByteSize]
  void _getChunk() {
    final length = _totalChunks == 1 ? _fileSize : _chunkByteSize;
    final start = length * _chunkCount;

    _chunk = file!.openRead(start, start + length);

    if (start + length <= _fileSize)
      _chunkLength = length;
    else
      _chunkLength = _fileSize - start;
  }

  /// Called on net failure. If retry [_attemptCount] < [attempts], retry after [delayBeforeAttempt]
  void _manageRetries({String? message}) {
    if (_attemptCount < attempts) {
      _attemptCount = _attemptCount + 1;
      Timer(Duration(seconds: delayBeforeAttempt), () => _sendChunks());

      if (_onAttemptFailure != null)
        _onAttemptFailure!(
          'An error occurred uploading chunk $_chunkCount. ${attempts - _attemptCount} retries left. $message',
          _chunkCount,
          attempts - _attemptCount,
        );

      return;
    }

    _uploadFailed = true;

    if (_onError != null)
      _onError!(
        'An error occurred uploading chunk $_chunkCount. No more retries, stopping upload',
        _chunkCount,
        _attemptCount,
      );
  }

  /// Manages the whole upload by calling [_getChunk] and [_sendChunk]
  void _sendChunks() {
    if (_paused || _offline || _stopped) return;

    _getEndpoint();
    _getChunk();
    _sendChunk().then(
      (res) {
        if (successfulChunkUploadCodes.contains(res.statusCode)) {
          _onChunkUploaded?.call(res.headers.map);

          _chunkCount++;
          if (_chunkCount < _totalChunks) {
            _attemptCount = 0;
            _sendChunks();
          } else {
            if (_onSuccess != null) _onSuccess!();
          }

          if (_onProgress != null) {
            double percentProgress = 100.0;
            if (_chunkCount < _totalChunks) {
              final bytesSent = _chunkCount * _chunkByteSize;
              percentProgress = bytesSent * 100.0 / _fileSize;
            }
            _onProgress!(percentProgress, _chunkCount);
          }
        } else if (temporaryErrorCodes.contains(res.statusCode)) {
          if (_paused || _offline || _stopped) return;

          _manageRetries();
        } else {
          if (_paused || _offline || _stopped) return;

          _uploadFailed = true;

          if (_onError != null)
            _onError!(
              'Server responded with ${res.statusCode}. Stopping upload.',
              _chunkCount,
              _attemptCount,
            );
        }
      },
      onError: (err) {
        if (_paused || _offline || _stopped) return;

        // this type of error can happen after network disconnection on CORS setup
        _manageRetries(message: err.toString());
      },
    );
  }

  /// Restarts the upload after if the upload failed and came to a complete stop
  void restart() {
    if (!_uploadFailed)
      throw Exception('Upload hasn\'t yet failed, please use restart only after all retries have failed.');

    _chunkCount = startChunk;
    _chunkByteSize = (_fileSize / endPoints!.length).ceil();
    _attemptCount = 0;
    _currentCancelToken = null;

    _offline = false;
    _paused = false;
    _stopped = false;
    _uploadFailed = false;

    _sendChunks();
  }
}
