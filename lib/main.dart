import 'package:english_words/english_words.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'package:snapping_sheet/snapping_sheet.dart';
import 'dart:ui';
import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

enum Status { unInitialized, authenticated, authenticating, unAuthenticated }

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(App());
}

class App extends StatelessWidget {
  final Future<FirebaseApp> _initialization = Firebase.initializeApp();
  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _initialization,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
              body: Center(
                  child: Text(snapshot.error.toString(),
                      textDirection: TextDirection.ltr)));
        }
        if (snapshot.connectionState == ConnectionState.done) {
          return const MyApp();
        }
        return const Center(child: CircularProgressIndicator());
      },
    );
  }
}

class AuthProvider with ChangeNotifier {
  final FirebaseAuth _auth;
  User? _user;
  Status _status = Status.unInitialized;

  AuthProvider.instance() : _auth = FirebaseAuth.instance {
    _auth.authStateChanges().listen(_onAuthStateChanged);
    _user = _auth.currentUser;
    _onAuthStateChanged(_user);
  }

  Status get status => _status;

  User? get user => _user;

  bool get isAuthenticated => _status == Status.authenticated;

  Future<UserCredential?> signUp(String email, String password) async {
    try {
      _status = Status.authenticating;
      notifyListeners();
      return await _auth.createUserWithEmailAndPassword(
          email: email, password: password);
    } catch (e) {
      print(e);
      _status = Status.unAuthenticated;
      notifyListeners();
      return null;
    }
  }

  Future<bool> signIn(String email, String password) async {
    try {
      _status = Status.authenticating;
      notifyListeners();
      await _auth.signInWithEmailAndPassword(email: email, password: password);
      return true;
    } catch (e) {
      _status = Status.unAuthenticated;
      notifyListeners();
      return false;
    }
  }

  Future signOut() async {
    _auth.signOut();
    _status = Status.unAuthenticated;
    notifyListeners();
    return Future.delayed(Duration.zero);
  }

  Future<void> _onAuthStateChanged(User? firebaseUser) async {
    if (firebaseUser == null) {
      _user = null;
      _status = Status.unAuthenticated;
    } else {
      _user = firebaseUser;
      _status = Status.authenticated;
    }
    notifyListeners();
  }
}

class FirebaseProvider extends ChangeNotifier {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  AuthProvider? _authProvider;
  final _suggestions = <WordPair>[];
  final _saved = <WordPair>{};
  final _biggerFont = const TextStyle(fontSize: 18);

  //This is the "no profile picture" case, just less boring
  final defaultAvatar = const NetworkImage(
      'https://i.pinimg.com/originals/76/35/a7/7635a74b32cb2df5346b5116823692ab.jpg');

  var _avatar;

  get saved => _saved;

  void removePair(WordPair pair) {
    _saved.remove(pair);
    _updateFavourites(remove: pair);
    notifyListeners();
  }

  Future getDoc(String? userID) async {
    final ref = await _firestore.collection("users").doc(userID).get();
    final snap = ref.data();
    if (snap == null) {
      return null;
    } else {
      return ref;
    }
  }

  void getAvatar() async {
    final uid = _authProvider?.user!.uid;
    final ref = _storage.ref("avatars/$uid");

    try {
      final url = await ref.getDownloadURL();
      _avatar = NetworkImage(url);
      notifyListeners();
    } catch (err) {
      return;
    }
  }

  void _getFavourites(AuthProvider authProvider) async {
    if (authProvider.isAuthenticated) {
      var ref = await getDoc(authProvider.user!.uid);
      if (ref == null) {
        _firestore
            .collection("users")
            .doc(authProvider.user!.uid)
            .set({"favourites": []});
      } else {
        _firestore
            .collection("users")
            .doc(authProvider.user!.uid)
            .get()
            .then((val) {
          var pairsSet = {
            ...List<String>.from(
                val.data() == null ? {} : val.data()!["favourites"])
          };
          var parsedPairs = pairsSet.map((pair) => WordPair(
              pair.split(RegExp(r"(?<=[a-z])(?=[A-Z])"))[0].toLowerCase(),
              pair.split(RegExp(r"(?<=[a-z])(?=[A-Z])"))[1].toLowerCase()));
          _saved.addAll(parsedPairs);
        }).then((val) {
          notifyListeners();
        });
      }
    }
  }

  void _updateFavourites({WordPair? remove}) {
    if (_authProvider == null) return;
    if (_authProvider!.isAuthenticated) {
      if (remove == null) {
        var newList = _saved.map((pair) => pair.asPascalCase).toList();
        _firestore.collection("users").doc(_authProvider!.user!.uid).update(
            {"favourites": FieldValue.arrayUnion(newList)}).then((value) {});
        return;
      }
      _firestore.collection("users").doc(_authProvider!.user!.uid).update({
        "favourites": FieldValue.arrayRemove([remove.asPascalCase])
      }).then((value) {});
    }
  }

  FirebaseProvider update(AuthProvider auth) {
    _getFavourites(auth);
    _authProvider = auth;
    _updateFavourites();
    return this;
  }

  Widget suggestions() {
    return ListView.builder(
      padding: const EdgeInsets.all(16.0),
      itemBuilder: (context, i) {
        if (i.isOdd) return const Divider();

        final index = i ~/ 2;
        if (index >= _suggestions.length) {
          _suggestions.addAll(generateWordPairs().take(10));
        }

        final alreadySaved = _saved.contains(_suggestions[index]);
        return ListTile(
            title: Text(
              _suggestions[index].asPascalCase,
              style: _biggerFont,
            ),
            trailing: Icon(
              alreadySaved ? Icons.favorite : Icons.favorite_border,
              color: alreadySaved ? Colors.red : null,
              semanticLabel: alreadySaved ? 'Remove from saved' : 'Save',
            ),
            onTap: () {
              if (alreadySaved) {
                _saved.remove(_suggestions[index]);
                _updateFavourites(remove: _suggestions[index]);
              } else {
                _saved.add(_suggestions[index]);
                _updateFavourites();
              }
              notifyListeners();
            });
      },
    );
  }
}

class _GrabbingWidget extends StatelessWidget {
  final Function() switchSheetStateFunc;

  const _GrabbingWidget(this.switchSheetStateFunc);

  @override
  Widget build(
    BuildContext context,
  ) {
    final userEmail =
        Provider.of<AuthProvider>(context, listen: false).user!.email!;

    return GestureDetector(
        onTap: () => switchSheetStateFunc(),
        child: Container(
          alignment: Alignment.centerLeft,
          color: const Color(0xFFCFD8DC),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            // crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                  ),
                  child: Text("Welcome back, $userEmail",
                      textAlign: TextAlign.left,
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 16,
                      ))),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Icon(Icons.keyboard_arrow_up_sharp),
              ),
            ],
          ),
        ));
  }
}

class BlurBackground extends StatelessWidget {
  const BlurBackground({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: 2.5,
          sigmaY: 2.5,
        ),
        child: Container(
          color: Colors.transparent,
        ),
      ),
    );
  }
}

class UserSnapSheet extends StatefulWidget {
  const UserSnapSheet({Key? key}) : super(key: key);

  @override
  State<UserSnapSheet> createState() => _UserSnapSheetState();
}

class _UserSnapSheetState extends State<UserSnapSheet> {
  var uid = "";
  String userEmail = "";
  final _imageStorage = FirebaseStorage.instance;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      child: ListView(
        children: [
          Row(
            children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: CircleAvatar(
                    backgroundColor: Colors.transparent,
                    radius: 40,
                    backgroundImage: Provider.of<FirebaseProvider>(context,
                                listen: true)
                            ._avatar ??
                        Provider.of<FirebaseProvider>(context, listen: false)
                            .defaultAvatar),
              ),
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text(
                        userEmail,
                        style: const TextStyle(
                          fontSize: 18,
                        ),
                      ),
                    ),
                    Container(
                      width: 150,
                      height: 30,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.lightBlue,
                        ),
                        onPressed: () {
                          _changeAvatar();
                        },
                        child: const Text(
                          "Change avatar",
                          textAlign: TextAlign.left,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    uid =
        Provider.of<AuthProvider>(context, listen: false).user!.uid.toString();
    userEmail = Provider.of<AuthProvider>(context, listen: false).user!.email!;
    Provider.of<FirebaseProvider>(context, listen: false).getAvatar();
  }

  void _changeAvatar() async {
    final XFile? image =
        await ImagePicker().pickImage(source: ImageSource.gallery);
    if (image == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('No image selected')));
      return;
    }
    var fileRef = _imageStorage.ref("avatars/$uid");
    await fileRef.putFile(File(image.path));
    context.read<FirebaseProvider>().getAvatar();
  }
}

class LoginSnapSheet extends StatefulWidget {
  const LoginSnapSheet({Key? key}) : super(key: key);

  @override
  State<LoginSnapSheet> createState() => _LoginSnapSheetState();
}

class _LoginSnapSheetState extends State<LoginSnapSheet> {
  final ScrollController scrollController = ScrollController();
  final snappingSheetController = SnappingSheetController();
  bool isSheetEnabled = false;

  @override
  Widget build(BuildContext context) {
    return SnappingSheet(
      controller: snappingSheetController,
      lockOverflowDrag: true,
      snappingPositions: getSnappingPositions(),
      grabbing: _GrabbingWidget(switchSheetState),
      grabbingHeight: 45,
      sheetAbove: isSheetEnabled
          ? SnappingSheetContent(child: const BlurBackground())
          : null,
      sheetBelow:
          SnappingSheetContent(child: const UserSnapSheet(), draggable: true),
    );
  }

  void switchSheetState() {
    setState(() {
      isSheetEnabled = !isSheetEnabled;
      snappingSheetController
          .setSnappingSheetFactor(isSheetEnabled ? 0.20 : 0.03);
    });
  }

  List<SnappingPosition> getSnappingPositions() {
    if (isSheetEnabled) {
      return const [
        SnappingPosition.factor(
          grabbingContentOffset: GrabbingContentOffset.bottom,
          snappingCurve: Curves.easeInExpo,
          snappingDuration: Duration(seconds: 1),
          positionFactor: 0.03,
        ),
        SnappingPosition.factor(
          grabbingContentOffset: GrabbingContentOffset.bottom,
          snappingCurve: Curves.easeInExpo,
          snappingDuration: Duration(seconds: 1),
          positionFactor: 1,
        )
      ];
    } else {
      return const [
        SnappingPosition.factor(
          grabbingContentOffset: GrabbingContentOffset.bottom,
          snappingCurve: Curves.easeInExpo,
          snappingDuration: Duration(seconds: 1),
          positionFactor: 0.08,
        )
      ];
    }
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => AuthProvider.instance()),
        ChangeNotifierProxyProvider<AuthProvider, FirebaseProvider>(
          create: (context) => FirebaseProvider(),
          update: (context, auth, firebaseProvider) =>
              firebaseProvider!.update(auth),
        ),
      ],
      child: MaterialApp(
        title: 'Startup Name Generator',
        theme: ThemeData(
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.deepPurple,
            foregroundColor: Colors.white,
          ),
        ),
        home: const RandomWords(),
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({Key? key}) : super(key: key);

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController passwordVerifyController =
      TextEditingController();
  bool _isLoading = false;
  bool _signingIn = false;
  bool _signingUp = false;
  bool _passwordMismatch = false;
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  void _handleTap() {
    setState(() {
      _isLoading = true;
    });
  }

  void failedSnackBar(String failString) {
    SnackBar failedSnackBar = SnackBar(
      content: Text(failString),
      duration: const Duration(seconds: 2),
      padding: const EdgeInsets.all(15.0),
    );
    ScaffoldMessenger.of(context).showSnackBar(failedSnackBar);
    setState(() {
      _isLoading = false;
      _signingUp = false;
      _signingIn = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: const Text('Login'),
        ),
        body: Padding(
            padding: const EdgeInsets.all(10),
            child: ListView(
              children: <Widget>[
                Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(10),
                    child: const Text(
                      'Welcome to Startup Names Generator, please log in!',
                      style: TextStyle(
                          color: Colors.deepPurple,
                          fontWeight: FontWeight.w500,
                          fontSize: 15),
                    )),
                Container(
                  padding: const EdgeInsets.all(10),
                  child: TextField(
                    controller: emailController,
                    obscureText: false,
                    cursorColor: Colors.deepPurple,
                    decoration: const InputDecoration(
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(
                            color: Color.fromARGB(85, 149, 117, 161)),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.deepPurple),
                      ),
                      border: UnderlineInputBorder(
                        borderSide: BorderSide(
                            color: Color.fromARGB(85, 149, 117, 161)),
                      ),
                      labelStyle: TextStyle(color: Colors.grey),
                      labelText: 'Email',
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(10),
                  child: TextField(
                    controller: passwordController,
                    obscureText: true,
                    cursorColor: Colors.deepPurple,
                    decoration: const InputDecoration(
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(
                            color: Color.fromARGB(85, 149, 117, 161)),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.deepPurple),
                      ),
                      border: UnderlineInputBorder(
                        borderSide: BorderSide(
                            color: Color.fromARGB(85, 149, 117, 161)),
                      ),
                      labelStyle: TextStyle(color: Colors.grey),
                      labelText: 'Password',
                    ),
                  ),
                ),
                Container(
                    height: 50,
                    padding: const EdgeInsets.fromLTRB(10, 5, 10, 0),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                          backgroundColor:
                              _isLoading ? Colors.grey : Colors.deepPurple,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20.0))),
                      onPressed: _isLoading
                          ? null
                          : () async {
                              _signingIn = true;
                              _handleTap();
                              AuthProvider.instance().signIn(
                                  emailController.text,
                                  passwordController.text);
                              await Future.delayed(const Duration(seconds: 1));
                              if (AuthProvider.instance()._status ==
                                  Status.authenticated) {
                                context
                                    .read<FirebaseProvider>()
                                    ._updateFavourites();
                                Navigator.of(context).pop();
                              } else {
                                failedSnackBar(
                                    'There was an error logging into the app');
                              }
                            },
                      child: _isLoading & _signingIn
                          ? const CircularProgressIndicator(color: Colors.white)
                          : const Text('Login'),
                    )),
                Container(
                    height: 50,
                    padding: const EdgeInsets.fromLTRB(10, 5, 10, 0),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                          backgroundColor:
                              _isLoading ? Colors.grey : Colors.lightBlue,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20.0))),
                      onPressed: _isLoading
                          ? null
                          : () async {
                              _signingUp = true;

                              await showModalBottomSheet<void>(
                                context: context,
                                builder: (BuildContext context) {
                                  return Form(
                                    key: _formKey,
                                    autovalidateMode: AutovalidateMode.disabled,
                                    child: SingleChildScrollView(
                                      child: AnimatedPadding(
                                        padding:
                                            MediaQuery.of(context).viewInsets,
                                        duration:
                                            const Duration(milliseconds: 100),
                                        curve: Curves.decelerate,
                                        child: Column(
                                          children: <Widget>[
                                            Container(
                                              color: Colors.green,
                                              child: const Material(
                                                child: ListTile(
                                                  title: Text(
                                                    'Please confirm your password below:',
                                                    textAlign: TextAlign.center,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            TextFormField(
                                                controller:
                                                    passwordVerifyController,
                                                obscureText: true,
                                                decoration:
                                                    const InputDecoration(
                                                  labelStyle: TextStyle(
                                                      color: Colors.grey),
                                                  labelText: 'Password',
                                                ),
                                                validator: (value) {
                                                  if (passwordVerifyController
                                                          .text !=
                                                      passwordController.text) {
                                                    _passwordMismatch = true;
                                                    return 'Passwords must match';
                                                  } else {
                                                    _passwordMismatch = false;
                                                    return null;
                                                  }
                                                }),
                                            Container(
                                                padding:
                                                    const EdgeInsets.all(10),
                                                child: ElevatedButton(
                                                    onPressed: () async {
                                                      if (_formKey.currentState!
                                                          .validate()) {
                                                        AuthProvider.instance()
                                                            .signUp(
                                                                emailController
                                                                    .text,
                                                                passwordController
                                                                    .text);
                                                        Navigator.of(context)
                                                            .pop(true);
                                                      } else {}
                                                    },
                                                    style: ElevatedButton.styleFrom(
                                                        padding:
                                                            const EdgeInsets
                                                                    .symmetric(
                                                                horizontal:
                                                                    40.0,
                                                                vertical: 10.0),
                                                        backgroundColor:
                                                            _isLoading
                                                                ? Colors.grey
                                                                : Colors
                                                                    .lightBlue),
                                                    child:
                                                        const Text("Confirm"))),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              );
                              if (!_passwordMismatch) {
                                _handleTap();
                                await Future.delayed(
                                    const Duration(seconds: 1));
                                if (AuthProvider.instance()._status ==
                                    Status.authenticated) {
                                  context
                                      .read<FirebaseProvider>()
                                      ._updateFavourites();
                                  Navigator.of(context).pop();
                                } else {
                                  failedSnackBar(
                                      'There was an error logging into the app');
                                }
                              }
                            },
                      child: _isLoading & _signingUp
                          ? const CircularProgressIndicator(color: Colors.white)
                          : const Text('New user? Click to sign up'),
                    ))
              ],
            )));
  }
}

class SavedPage extends StatefulWidget {
  const SavedPage({Key? key}) : super(key: key);

  @override
  State<SavedPage> createState() => _SavedPageState();
}

class _SavedPageState extends State<SavedPage> {
  final _biggerFont = const TextStyle(fontSize: 18);
  Future<bool?> alertDialog(WordPair pair) {
    AlertDialog alert = AlertDialog(
      title: const Text('Delete Suggestion'),
      content: Text(
        'Are you sure you want to delete $pair from your saved suggestions?',
      ),
      actions: [
        TextButton(
          onPressed: () {
            Provider.of<FirebaseProvider>(context, listen: false)
                .removePair(pair);
            Navigator.of(context).pop(true);
          },
          style: TextButton.styleFrom(
            backgroundColor: Colors.deepPurple,
          ),
          child: const Text(
            'Yes',
            style: TextStyle(color: Colors.white),
          ),
        ),
        TextButton(
          onPressed: () {
            Navigator.of(context).pop(false);
          },
          style: TextButton.styleFrom(
            backgroundColor: Colors.deepPurple,
          ),
          child: const Text(
            'No',
            style: TextStyle(color: Colors.white),
          ),
        ),
      ],
    );
    return showDialog<bool?>(
      context: context,
      builder: (BuildContext context) => alert,
    );
  }

  @override
  Widget build(BuildContext context) {
    final saved = Provider.of<FirebaseProvider>(context, listen: false).saved;
    final tiles = saved.map<Widget>(
      (pair) {
        return Dismissible(
          key: Key(pair.asPascalCase),
          background: Container(
              color: Colors.deepPurple,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              alignment: AlignmentDirectional.centerStart,
              child: Row(children: const [
                Icon(
                  Icons.delete,
                  color: Colors.white,
                ),
                Text(
                  'Delete suggestion',
                  style: TextStyle(color: Colors.white),
                )
              ])),
          confirmDismiss: (direction) {
            return alertDialog(pair);
          },
          onDismissed: (_) => context.read<FirebaseProvider>().removePair(pair),
          child: ListTile(title: Text(pair.asPascalCase, style: _biggerFont)),
        );
      },
    );
    final divided = tiles.isNotEmpty
        ? ListTile.divideTiles(
            context: context,
            tiles: tiles,
          ).toList()
        : <Widget>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved Suggestions'),
      ),
      body: ListView(children: divided),
    );
  }
}

class RandomWords extends StatefulWidget {
  const RandomWords({Key? key}) : super(key: key);

  @override
  State<RandomWords> createState() => _RandomWordsState();
}

class _RandomWordsState extends State<RandomWords> {
  void _pushSaved() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) {
          return const SavedPage();
        },
      ),
    );
  }

  void _login() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) {
          return const LoginPage();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<AuthProvider, FirebaseProvider>(
        builder: (context, authProvider, firebaseProvider, child) {
      return Scaffold(
          appBar: AppBar(
            title: const Text('Startup Name Generator'),
            actions: [
              IconButton(
                  icon: const Icon(Icons.list),
                  onPressed: _pushSaved,
                  tooltip: 'Saved Suggestions'),
              !context.watch<AuthProvider>().isAuthenticated
                  ? IconButton(
                      icon: const Icon(Icons.login),
                      onPressed: _login,
                    )
                  : IconButton(
                      icon: const Icon(Icons.exit_to_app),
                      onPressed: () {
                        AuthProvider.instance().signOut();
                        SnackBar snackBar = const SnackBar(
                          content: Text('Successfully logged out'),
                          duration: Duration(seconds: 3),
                          padding: EdgeInsets.all(15.0),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(snackBar);
                      })
            ],
          ),
          body: Stack(
            children: <Widget>[
              Center(
                child: firebaseProvider.suggestions(),
              ),
              context.watch<AuthProvider>().isAuthenticated
                  ? const LoginSnapSheet()
                  : const SizedBox.shrink()
            ],
          ));
    });
  }
}
