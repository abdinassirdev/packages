// Copyright 2019 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/people/v1.dart';

GoogleSignIn _googleSignIn = GoogleSignIn(
  scopes: <String>[
    'email',
    'https://www.googleapis.com/auth/contacts.readonly',
  ],
);

void main() {
  runApp(
    const MaterialApp(
      title: 'Google Sign In',
      home: SignInDemo(),
    ),
  );
}

/// The main widget of this demo.
class SignInDemo extends StatefulWidget {
  /// Creates the main widget of this demo.
  const SignInDemo({Key? key}) : super(key: key);

  @override
  State createState() => SignInDemoState();
}

/// The state of the main widget.
class SignInDemoState extends State<SignInDemo> {
  GoogleSignInAccount? _currentUser;
  String? _contactText;

  @override
  void initState() {
    super.initState();
    _googleSignIn.onCurrentUserChanged.listen((GoogleSignInAccount? account) {
      setState(() {
        _currentUser = account;
      });
      if (_currentUser != null) {
        _handleGetContact();
      }
    });
    _googleSignIn.signInSilently();
  }

  Future<void> _handleGetContact() async {
    setState(() {
      _contactText = 'Loading contact info...';
    });

    final PeopleServiceApi peopleApi =
        PeopleServiceApi((await _googleSignIn.authenticatedClient())!);
    final ListConnectionsResponse response =
        await peopleApi.people.connections.list(
      'people/me',
      personFields: 'names',
    );

    final String? firstNamedContactName =
        _pickFirstNamedContact(response.connections);

    setState(() {
      if (firstNamedContactName != null) {
        _contactText = 'I see you know $firstNamedContactName!';
      } else {
        _contactText = 'No contacts to display.';
      }
    });
  }

  String? _pickFirstNamedContact(List<Person>? connections) {
    return connections
        ?.firstWhere(
          (Person person) => person.names != null,
        )
        .names
        ?.firstWhere(
          (Name name) => name.displayName != null,
        )
        .displayName;
  }

  Future<void> _handleSignIn() async {
    try {
      await _googleSignIn.signIn();
    } catch (error) {
      print(error);
    }
  }

  Future<void> _handleSignOut() => _googleSignIn.disconnect();

  Widget _buildBody() {
    if (_currentUser != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: <Widget>[
          ListTile(
            leading: GoogleUserCircleAvatar(
              identity: _currentUser!,
            ),
            title: Text(_currentUser!.displayName ?? ''),
            subtitle: Text(_currentUser!.email),
          ),
          const Text('Signed in successfully.'),
          Text(_contactText ?? ''),
          ElevatedButton(
            child: const Text('SIGN OUT'),
            onPressed: _handleSignOut,
          ),
          ElevatedButton(
            child: const Text('REFRESH'),
            onPressed: _handleGetContact,
          ),
        ],
      );
    } else {
      return Column(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: <Widget>[
          const Text('You are not currently signed in.'),
          ElevatedButton(
            child: const Text('SIGN IN'),
            onPressed: _handleSignIn,
          ),
        ],
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: const Text('Google Sign In'),
        ),
        body: ConstrainedBox(
          constraints: const BoxConstraints.expand(),
          child: _buildBody(),
        ));
  }
}
