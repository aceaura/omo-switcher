import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omo_switcher_client/main.dart';

void main() {
  test('checks versioned baseURL without duplicating v1', () async {
    final requestedPaths = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final done = server.listen((request) async {
      requestedPaths.add(request.uri.path);
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      expect(body['model'], 'gpt-5.5');
      expect(body['stream'], isNull);
      expect(body['max_tokens'], 1);

      if (request.uri.path == '/v1/chat/completions') {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('{"id":"ok"}');
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('unexpected path');
      }
      await request.response.close();
    });
    addTearDown(() => done.cancel());

    final message = await checkModelConnectivity(
      ModelCheckTarget(
        model: 'newapi/gpt-5.5',
        variant: null,
        locations: const ['test'],
        providerId: 'newapi',
        modelId: 'gpt-5.5',
        baseUrl: 'http://${server.address.host}:${server.port}/v1',
        apiKey: 'test-key',
        error: null,
      ),
    );

    expect(message, contains('/v1/chat/completions'));
    expect(requestedPaths, ['/v1/chat/completions']);
  });

  test(
    'uses non-stream probe before stream fallback for qwen-compatible routes',
    () async {
      final streamFlags = <Object?>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final done = server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        streamFlags.add(body['stream']);

        if (body['stream'] == true) {
          request.response.statusCode = HttpStatus.unauthorized;
          request.response.write(
            jsonEncode({
              'error': {
                'message':
                    'Model qwen3.7-max is not supported for format oa-compat',
              },
            }),
          );
        } else {
          request.response.statusCode = HttpStatus.ok;
          request.response.write('{"id":"ok"}');
        }
        await request.response.close();
      });
      addTearDown(() => done.cancel());

      final message = await checkModelConnectivity(
        ModelCheckTarget(
          model: 'newapi/qwen3.7-max',
          variant: 'high',
          locations: const ['test'],
          providerId: 'newapi',
          modelId: 'qwen3.7-max',
          baseUrl: 'http://${server.address.host}:${server.port}/v1',
          apiKey: 'test-key',
          error: null,
        ),
      );

      expect(message, contains('请求成功'));
      expect(streamFlags, [null]);
    },
  );

  test('falls back to stream probe when non-stream is rejected', () async {
    final streamFlags = <Object?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final done = server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      streamFlags.add(body['stream']);

      if (body['stream'] == true) {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('data: {"id":"ok"}\n\n');
      } else {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(
          jsonEncode({
            'error': {'message': 'non-stream probe rejected'},
          }),
        );
      }
      await request.response.close();
    });
    addTearDown(() => done.cancel());

    final message = await checkModelConnectivity(
      ModelCheckTarget(
        model: 'newapi/gpt-5.5',
        variant: null,
        locations: const ['test'],
        providerId: 'newapi',
        modelId: 'gpt-5.5',
        baseUrl: 'http://${server.address.host}:${server.port}/v1',
        apiKey: 'test-key',
        error: null,
      ),
    );

    expect(message, contains('请求成功'));
    expect(streamFlags, [null, true]);
  });
}
