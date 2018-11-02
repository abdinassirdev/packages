// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/src/constants.dart';
import 'package:multicast_dns/src/lookup_resolver.dart';
import 'package:multicast_dns/src/native_protocol_client.dart';
import 'package:multicast_dns/src/packet.dart';
import 'package:multicast_dns/src/resource_record.dart';

export 'package:multicast_dns/src/resource_record.dart';

/// A callback type for [MDnsQuerier.start] to iterate available network interfaces.
///
/// Impelmentations must ensure they return interfaces appropriate for the [type] parameter.
///
/// See also:
///   * [MDnsQuerier.allInterfacesFactory]
typedef NetworkInterfacesFactory = Future<Iterable<NetworkInterface>> Function(
    InternetAddressType type);

/// Client for DNS lookup and publishing using the mDNS protocol.
///
/// Users should call [MDnsQuerier.start] when ready to start querying and listening.
/// [MDnsQuerier.stop] must be called when done to clean up resources.
///
/// This client only support "One-Shot Multicast DNS Queries" as described in
/// section 5.1 of [RFC 6762](https://tools.ietf.org/html/rfc6762).
class MDnsClient {
  bool _starting = false;
  bool _started = false;
  RawDatagramSocket _incoming;
  final List<RawDatagramSocket> _sockets = <RawDatagramSocket>[];
  final LookupResolver _resolver = LookupResolver();
  final ResourceRecordCache _cache = ResourceRecordCache();
  InternetAddress _mDnsAddress;

  /// Find all network interfaces with an the [InternetAddressType] specified.
  static NetworkInterfacesFactory allInterfacesFactory =
      (InternetAddressType type) => NetworkInterface.list(
            includeLinkLocal: true,
            type: type,
            includeLoopback: true,
          );

  /// Start the mDNS client.
  ///
  /// With no arguments, this method will listen on the IPv4 multicast address
  /// on all IPv4 network interfaces.
  ///
  /// The [listenAddress] parameter must be either [InternetAddress.anyIPv4] or
  /// [InternetAddress.anyIPv6], and will default to anyIPv4.
  ///
  /// The [interfaceFactory] defaults to [allInterfacesFactory].
  Future<void> start({
    InternetAddress listenAddress,
    NetworkInterfacesFactory interfacesFactory,
  }) async {
    listenAddress ??= InternetAddress.anyIPv4;
    interfacesFactory ??= allInterfacesFactory;

    assert(listenAddress.address == InternetAddress.anyIPv4.address ||
        listenAddress.address == InternetAddress.anyIPv6.address);

    if (_started || _starting) {
      return;
    }
    _starting = true;

    // Listen on all addresses.
    _incoming = await RawDatagramSocket.bind(
      listenAddress.address,
      mDnsPort,
      reuseAddress: true,
      reusePort: true,
      ttl: 255,
    );

    // Can't send to IPv6 any address.
    if (_incoming.address != InternetAddress.anyIPv6) {
      _sockets.add(_incoming);
    }

    _mDnsAddress = _incoming.address.type == InternetAddressType.IPv4
        ? mDnsAddressIPv4
        : mDnsAddressIPv6;

    final List<NetworkInterface> interfaces =
        await interfacesFactory(listenAddress.type);

    for (NetworkInterface interface in interfaces) {
      // Create a socket for sending on each adapter.
      final RawDatagramSocket socket = await RawDatagramSocket.bind(
        interface.addresses[0],
        mDnsPort,
        reuseAddress: true,
        reusePort: true,
        ttl: 255,
      );
      _sockets.add(socket);
      // socket.listen(_handleIncoming);

      // Join multicast on this interface.
      print('Adding ${socket.address} to group');
      _incoming.joinMulticast(_mDnsAddress, interface);
      print(socket.multicastAddress);

      socket.multicastAddress = interface.addresses[0];
      print(socket.multicastAddress);
      socket.multicastAddress = null;
      print(socket.multicastAddress);
      socket.multicastAddress = interface.addresses[0];
      print(socket.multicastAddress);
    }
    _incoming.listen(_handleIncoming);
    _started = true;
    _starting = false;
  }

  /// Stop the client and close any associated sockets.
  void stop() {
    if (!_started) {
      return;
    }
    if (_starting) {
      throw StateError('Cannot stop mDNS client while it is starting.');
    }

    for (RawDatagramSocket socket in _sockets) {
      socket.close();
    }

    _resolver.clearPendingRequests();

    _started = false;
  }

  /// Lookup a [ResourceRecord], potentially from cache.
  ///
  /// The [type] parameter must be a valid [ResourceRecordType].  The [name] parameter is
  /// the name of the service to lookup, and must not be null.  The [timeout]
  /// parameter specifies how long the intenral cache should hold on to the
  /// record.  The [multicast] parameter specifies whether the query should be
  /// sent as unicast (QU) or multicast (QM).
  ///
  /// Note that some publishers have been observed to not respond to unicast
  /// requests properly, so the default is true.
  Stream<T> lookup<T extends ResourceRecord>(
    ResourceRecordQuery query, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    if (!_started) {
      throw StateError('mDNS client is not started.');
    }
    // Look for entries in the cache.
    final List<T> cached = <T>[];
    _cache.lookup<T>(query.name, query.resourceRecordType, cached);
    if (cached.isNotEmpty) {
      final StreamController<T> controller = StreamController<T>();
      cached.forEach(controller.add);
      controller.close();
      return controller.stream;
    }

    // Add the pending request before sending the query.
    final Stream<T> results = _resolver.addPendingRequest<T>(
        query.resourceRecordType, query.name, timeout);

    // Send the request on all interfaces.
    final List<int> packet = query.encode();
    for (RawDatagramSocket socket in _sockets) {
      socket.send(packet, _mDnsAddress, mDnsPort);
    }
    return results;
  }

  // Process incoming datagrams.
  void _handleIncoming(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      final Datagram datagram = _incoming.receive();

      // check for published responses
      // _dumpDatagram(datagram);
      final List<ResourceRecord> response = decodeMDnsResponse(datagram.data);
      if (response != null) {
        _cache.updateRecords(response);
        _resolver.handleResponse(response);
        return;
      }
      // TODO(dnfield): Support queries coming in for published entries.
    }
  }
}

void _dumpDatagram(Datagram datagram) {
  String _toHex(List<int> ints) {
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < ints.length; i++) {
      buffer.write(ints[i].toRadixString(16).padLeft(2, '0'));
      if ((i + 1) % 10 == 0) {
        buffer.writeln();
      } else {
        buffer.write(' ');
      }
    }
    return buffer.toString();
  }

  print('${datagram.address.address}:${datagram.port}:');
  print(_toHex(datagram.data));
  print('');
}
