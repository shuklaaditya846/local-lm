import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LLM Chat',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const MainNavigation(),
    );
  }
}

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;

  final List<Widget> _pages = [
    const HomePage(),
    const SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.chat),
            label: 'Chat',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class ConversationEntry {
  final String userText;
  final String responseText;
  final DateTime timestamp;
  final String id;

  ConversationEntry({
    required this.userText,
    required this.responseText,
    required this.timestamp,
    required this.id,
  });

  Map<String, dynamic> toJson() => {
    'userText': userText,
    'responseText': responseText,
    'timestamp': timestamp.toIso8601String(),
    'id': id,
  };

  factory ConversationEntry.fromJson(Map<String, dynamic> json) {
    return ConversationEntry(
      userText: json['userText'],
      responseText: json['responseText'],
      timestamp: DateTime.parse(json['timestamp']),
      id: json['id'],
    );
  }
}

class ChatHistory {
  String id;
  String title;
  final List<ConversationEntry> entries;
  final DateTime createdAt;
  DateTime updatedAt;

  ChatHistory({
    required this.id,
    required this.title,
    required this.entries,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'entries': entries.map((e) => e.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory ChatHistory.fromJson(Map<String, dynamic> json) {
    return ChatHistory(
      id: json['id'],
      title: json['title'],
      entries: (json['entries'] as List)
          .map((e) => ConversationEntry.fromJson(e))
          .toList(),
      createdAt: DateTime.parse(json['createdAt']),
      updatedAt: DateTime.parse(json['updatedAt']),
    );
  }
}

class StorageService {
  static const String _chatHistoryKey = 'chat_history';
  static const String _systemPromptKey = 'system_prompt';
  static const String _autoSaveTimeKey = 'auto_save_time';

  static Future<SharedPreferences> get _prefs async =>
      await SharedPreferences.getInstance();

  static Future<void> saveChatHistory(List<ChatHistory> history) async {
    final prefs = await _prefs;
    final jsonList = history.map((h) => h.toJson()).toList();
    await prefs.setString(_chatHistoryKey, jsonEncode(jsonList));
  }

  static Future<List<ChatHistory>> loadChatHistory() async {
    final prefs = await _prefs;
    final jsonString = prefs.getString(_chatHistoryKey);
    if (jsonString == null) return [];
    try {
      final jsonList = jsonDecode(jsonString) as List;
      return jsonList.map((e) => ChatHistory.fromJson(e)).toList();
    } catch (e) {
      return [];
    }
  }

  static Future<void> saveSystemPrompt(String prompt) async {
    final prefs = await _prefs;
    await prefs.setString(_systemPromptKey, prompt);
  }

  static Future<String> loadSystemPrompt() async {
    final prefs = await _prefs;
    return prefs.getString(_systemPromptKey) ?? 'You are a helpful assistant.';
  }

  static Future<void> saveAutoSaveTime(int minutes) async {
    final prefs = await _prefs;
    await prefs.setInt(_autoSaveTimeKey, minutes);
  }

  static Future<int> loadAutoSaveTime() async {
    final prefs = await _prefs;
    return prefs.getInt(_autoSaveTimeKey) ?? 30;
  }

  static Future<void> clearAllData() async {
    final prefs = await _prefs;
    await prefs.clear();
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final LlamaController _controller = LlamaController();
  final List<ChatHistory> _chatHistories = [];
  ChatHistory? _currentChat;
  bool _isLoading = false;
  bool _modelLoaded = false;
  String? _selectedModelPath;
  Timer? _inactivityTimer;
  int _autoSaveTime = 30;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    _chatHistories.addAll(await StorageService.loadChatHistory());
    _autoSaveTime = await StorageService.loadAutoSaveTime();
    setState(() {});
  }

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(Duration(minutes: _autoSaveTime), () {
      if (_modelLoaded) {
        _saveCurrentChat();
        _unloadModel();
      }
    });
  }

  Future<void> _pickModelFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['gguf'],
    );

    if (result != null && result.files.single.path != null) {
      String? pickedPath = result.files.single.path;
      setState(() {
        _selectedModelPath = pickedPath;
        _isLoading = true;
        _modelLoaded = false;
      });

      try {
        await _controller.loadModel(
          modelPath: pickedPath!,
          threads: 4,
          contextSize: 2048,
        );
        setState(() {
          _modelLoaded = true;
        });
        _startNewChat();
        _resetInactivityTimer();
      } catch (err) {
        print("Failed to load model: $err");
        setState(() {
          _modelLoaded = false;
        });
        _showError('Error loading model: $err');
      } finally {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _startNewChat() {
    setState(() {
      _currentChat = ChatHistory(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: 'New Chat',
        entries: [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
    });
  }

  Future<void> _saveCurrentChat() async {
    if (_currentChat != null && _currentChat!.entries.isNotEmpty) {
      // Remove existing chat with same ID and add updated one
      _chatHistories.removeWhere((chat) => chat.id == _currentChat!.id);
      _chatHistories.insert(0, _currentChat!);

      await StorageService.saveChatHistory(_chatHistories);
      setState(() {});
    }
  }

  Future<void> _deleteChatHistory(String id) async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Chat'),
        content: const Text('Are you sure you want to delete this chat?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              _chatHistories.removeWhere((chat) => chat.id == id);
              if (_currentChat?.id == id) {
                _currentChat = null;
              }
              StorageService.saveChatHistory(_chatHistories);
              setState(() {});
              Navigator.pop(context);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _loadChat(ChatHistory chat) {
    setState(() {
      _currentChat = chat;
    });
    _resetInactivityTimer();
  }

  Future<void> _unloadModel() async {
    if (_modelLoaded) {
      await _saveCurrentChat();
      await _controller.dispose();
      setState(() {
        _modelLoaded = false;
        _selectedModelPath = null;
        _currentChat = null;
      });
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  @override
  void dispose() {
    _inactivityTimer?.cancel();
    _saveCurrentChat();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('LLM Chat'),
            if (_currentChat != null && _currentChat!.title == 'New Chat')
              Text(
                'New Chat',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.white70,
                  fontSize: 12,
                ),
              ),
          ],
        ),
        actions: [
          if (_modelLoaded && _currentChat != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _startNewChat,
              tooltip: 'New Chat',
            ),
        ],
      ),
      body: Column(
        children: [
          _buildModelStatus(),
          Expanded(
            child: _currentChat != null && _modelLoaded
                ? ChatWidget(
              chat: _currentChat!,
              controller: _controller,
              onUpdate: () {
                setState(() {});
                _resetInactivityTimer();
                _saveCurrentChat();
              },
            )
                : _buildHistoryList(),
          ),
        ],
      ),
    );
  }

  Widget _buildModelStatus() {
    return Container(
      padding: const EdgeInsets.all(12),
      color: _modelLoaded ? Colors.green[50] : Colors.orange[50],
      child: Row(
        children: [
          Icon(
            _modelLoaded ? Icons.check_circle : Icons.error_outline,
            color: _modelLoaded ? Colors.green : Colors.orange,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _modelLoaded
                  ? 'Model loaded: ${_selectedModelPath?.split('/').last}'
                  : 'No model loaded',
              style: TextStyle(
                color: _modelLoaded ? Colors.green : Colors.orange,
              ),
            ),
          ),
          if (!_modelLoaded)
            ElevatedButton(
              onPressed: _isLoading ? null : _pickModelFile,
              child: _isLoading
                  ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
                  : const Text('Load Model'),
            ),
          if (_modelLoaded)
            IconButton(
              icon: const Icon(Icons.unarchive),
              onPressed: _unloadModel,
              tooltip: 'Unload Model',
            ),
        ],
      ),
    );
  }

  Widget _buildHistoryList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Chat History',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              if (_isLoading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
        Expanded(
          child: _chatHistories.isEmpty
              ? const Center(
            child: Text(
              'No chat history yet.\nLoad a model to start chatting!',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          )
              : ListView.builder(
            itemCount: _chatHistories.length,
            itemBuilder: (context, index) {
              final chat = _chatHistories[index];
              return Card(
                margin: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 4),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Theme.of(context).primaryColor,
                    child: Text(
                      '${index + 1}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  title: Text(
                    chat.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${chat.entries.length} messages',
                        style: const TextStyle(fontSize: 12),
                      ),
                      Text(
                        DateFormat('MMM dd, HH:mm').format(chat.updatedAt),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                  onTap: () => _loadChat(chat),
                  onLongPress: () => _deleteChatHistory(chat.id),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete,
                        color: Colors.red, size: 20),
                    onPressed: () => _deleteChatHistory(chat.id),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class ChatWidget extends StatefulWidget {
  final ChatHistory chat;
  final LlamaController controller;
  final VoidCallback onUpdate;

  const ChatWidget({
    super.key,
    required this.chat,
    required this.controller,
    required this.onUpdate,
  });

  @override
  State<ChatWidget> createState() => _ChatWidgetState();
}

class _ChatWidgetState extends State<ChatWidget> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isGenerating = false;
  bool _isGeneratingTitle = false;
  StreamSubscription? _generationSubscription;
  StreamSubscription? _titleGenerationSubscription;

  @override
  void dispose() {
    _generationSubscription?.cancel();
    _titleGenerationSubscription?.cancel();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _generateChatTitle(String userMessage) async {
    if (_isGeneratingTitle ||
        !widget.chat.entries.any((entry) => entry.responseText.isNotEmpty)) {
      return;
    }

    setState(() {
      _isGeneratingTitle = true;
    });

    try {
      final titlePrompt = '''
Create a very short, concise title (2-4 words maximum) that captures the essence of this user query. 
The title should be specific, descriptive, and helpful for identifying the conversation later.

User query: "$userMessage"

Requirements:
- Maximum 4 words
- No quotes or punctuation
- Be specific and descriptive
- Use title case

Title:''';

      final List<String> titleTokens = [];
      String generatedTitle = '';

      final completer = Completer<void>();

      _titleGenerationSubscription = widget.controller
          .generateChat(
        messages: [ChatMessage(role: 'user', content: titlePrompt)],
        maxTokens: 15,
        temperature: 0.4,

        // stop: ['\n', '.', '?', '!'],
      )
          .listen(
            (token) {
          titleTokens.add(token);
          generatedTitle = titleTokens.join('').trim();
          generatedTitle = _cleanTitle(generatedTitle);
          if (generatedTitle.isNotEmpty && _isValidTitle(generatedTitle)) {
            widget.chat.title = generatedTitle;
            widget.onUpdate();
          }
        },
        onDone: () {
          completer.complete();
        },
        onError: (error) {
          print('Title generation error: $error');
          completer.complete();
        },
      );

      await completer.future.timeout(const Duration(seconds: 5));

      if (generatedTitle.isEmpty || !_isValidTitle(generatedTitle)) {
        generatedTitle = _createFallbackTitle(userMessage);
      }

      widget.chat.title = generatedTitle;
      widget.onUpdate();
    } catch (e) {
      print('Error generating title: $e');
      widget.chat.title = _createFallbackTitle(userMessage);
      widget.onUpdate();
    } finally {
      setState(() {
        _isGeneratingTitle = false;
      });
      _titleGenerationSubscription?.cancel();
    }
  }

  String _cleanTitle(String title) {
    return title
        .replaceAll('"', '')
        .replaceAll("'", '')
        .replaceAll('.', '')
        .replaceAll('?', '')
        .replaceAll('!', '')
        .replaceAll('Title:', '')
        .replaceAll('title:', '')
        .trim();
  }

  bool _isValidTitle(String title) {
    if (title.isEmpty) return false;
    if (title.length > 50) return false;
    if (title.split(' ').length > 6) return false;
    if (title.toLowerCase().contains('user query')) return false;
    if (title.toLowerCase().contains('title:')) return false;
    return true;
  }

  String _createFallbackTitle(String userMessage) {
    final words = userMessage.split(' ');
    if (words.length <= 4) {
      return userMessage;
    } else {
      return '${words.take(4).join(' ')}...';
    }
  }

  Future<void> _sendMessage() async {
    if (_textController.text.trim().isEmpty || _isGenerating) return;

    final userText = _textController.text.trim();
    _textController.clear();

    final userEntry = ConversationEntry(
      userText: userText,
      responseText: '',
      timestamp: DateTime.now(),
      id: DateTime.now().millisecondsSinceEpoch.toString(),
    );

    setState(() {
      widget.chat.entries.add(userEntry);
      _isGenerating = true;
    });
    _scrollToBottom();

    final messages = widget.chat.entries
        .map((entry) => ChatMessage(
      role: entry.responseText.isEmpty ? 'user' : 'assistant',
      content: entry.responseText.isEmpty
          ? entry.userText
          : entry.responseText,
    ))
        .toList();

    final List<String> aiTokens = [];
    _generationSubscription = widget.controller
        .generateChat(
      messages: messages,
      maxTokens: 512,
      temperature: 0.7,
    )
        .listen(
          (token) {
        aiTokens.add(token);
        setState(() {
          if (widget.chat.entries.last.responseText.isEmpty) {
            final aiEntry = ConversationEntry(
              userText: '',
              responseText: aiTokens.join(''),
              timestamp: DateTime.now(),
              id: 'ai_${DateTime.now().millisecondsSinceEpoch}',
            );
            widget.chat.entries.add(aiEntry);
          } else {
            final lastEntry = widget.chat.entries.last;
            widget.chat.entries[widget.chat.entries.length - 1] =
                ConversationEntry(
                  userText: lastEntry.userText,
                  responseText: aiTokens.join(''),
                  timestamp: lastEntry.timestamp,
                  id: lastEntry.id,
                );
          }
        });
        _scrollToBottom();
      },
      onDone: () {
        setState(() {
          _isGenerating = false;
        });

        final completedExchanges = widget.chat.entries
            .where((entry) => entry.userText.isNotEmpty)
            .where((entry) {
          final responseIndex = widget.chat.entries.indexOf(entry) + 1;
          return responseIndex < widget.chat.entries.length &&
              widget.chat.entries[responseIndex].responseText.isNotEmpty;
        }).length;

        if (completedExchanges == 1) {
          _generateChatTitle(userText);
        }

        widget.onUpdate();
        _generationSubscription?.cancel();
      },
      onError: (error) {
        setState(() {
          _isGenerating = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Generation error: $error'),
            backgroundColor: Colors.red,
          ),
        );
        _generationSubscription?.cancel();
      },
    );
  }

  void _editMessage(int index) {
    final entry = widget.chat.entries[index];
    final controller = TextEditingController(text: entry.userText);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Message'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                setState(() {
                  widget.chat.entries[index] = ConversationEntry(
                    userText: controller.text.trim(),
                    responseText: entry.responseText,
                    timestamp: entry.timestamp,
                    id: entry.id,
                  );
                });
                widget.onUpdate();
              }
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _copyToClipboard(String text) {
    // For actual clipboard functionality, add: flutter pub add clipboard
    // Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  void _regenerateResponse(int index) {
    if (index < widget.chat.entries.length - 1) {
      widget.chat.entries.removeAt(index + 1);
      widget.onUpdate();
      _sendMessage();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(16),
            itemCount: widget.chat.entries.length,
            itemBuilder: (context, index) {
              final entry = widget.chat.entries[index];
              final isUser = entry.userText.isNotEmpty;

              return ChatBubble(
                message: isUser ? entry.userText : entry.responseText,
                isUser: isUser,
                onEdit: isUser ? () => _editMessage(index) : null,
                onCopy: () => _copyToClipboard(
                    isUser ? entry.userText : entry.responseText),
                onRegenerate: !isUser ? () => _regenerateResponse(index) : null,
                isGenerating: !isUser &&
                    index == widget.chat.entries.length - 1 &&
                    _isGenerating,
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _textController,
                  decoration: InputDecoration(
                    hintText: 'Type your message...',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  maxLines: null,
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: _isGenerating
                    ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                    : const Icon(Icons.send),
                onPressed: _isGenerating ? null : _sendMessage,
                style: IconButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                  shape: const CircleBorder(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class ChatBubble extends StatelessWidget {
  final String message;
  final bool isUser;
  final VoidCallback? onEdit;
  final VoidCallback? onCopy;
  final VoidCallback? onRegenerate;
  final bool isGenerating;

  const ChatBubble({
    super.key,
    required this.message,
    required this.isUser,
    this.onEdit,
    this.onCopy,
    this.onRegenerate,
    this.isGenerating = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser)
            CircleAvatar(
              radius: 16,
              backgroundColor: Colors.green,
              child: Text(
                'AI',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                ),
              ),
            ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isUser
                    ? Theme.of(context).primaryColor.withOpacity(0.1)
                    : Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isGenerating && message.isEmpty)
                    const Row(
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text('Thinking...'),
                      ],
                    )
                  else
                    Text(
                      message,
                      style: const TextStyle(fontSize: 16),
                    ),
                  if (!isGenerating && message.isNotEmpty)
                    const SizedBox(height: 8),
                  if (!isGenerating && message.isNotEmpty)
                    Row(
                      children: [
                        if (onCopy != null)
                          _buildActionButton(
                            Icons.copy,
                            'Copy',
                            onCopy!,
                          ),
                        if (onEdit != null)
                          _buildActionButton(
                            Icons.edit,
                            'Edit',
                            onEdit!,
                          ),
                        if (onRegenerate != null)
                          _buildActionButton(
                            Icons.refresh,
                            'Regenerate',
                            onRegenerate!,
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          if (isUser)
            CircleAvatar(
              radius: 16,
              backgroundColor: Theme.of(context).primaryColor,
              child: const Text(
                'U',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildActionButton(IconData icon, String tooltip, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: IconButton(
        icon: Icon(icon, size: 16),
        onPressed: onTap,
        tooltip: tooltip,
        style: IconButton.styleFrom(
          padding: const EdgeInsets.all(4),
        ),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _systemPromptController = TextEditingController();
  final TextEditingController _autoSaveController = TextEditingController();
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prompt = await StorageService.loadSystemPrompt();
    final autoSaveTime = await StorageService.loadAutoSaveTime();

    setState(() {
      _systemPromptController.text = prompt;
      _autoSaveController.text = autoSaveTime.toString();
    });
  }

  Future<void> _saveSettings() async {
    setState(() {
      _isSaving = true;
    });

    try {
      await StorageService.saveSystemPrompt(_systemPromptController.text);
      await StorageService.saveAutoSaveTime(
          int.tryParse(_autoSaveController.text) ?? 30);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error saving settings: $e')),
      );
    } finally {
      setState(() {
        _isSaving = false;
      });
    }
  }

  Future<void> _clearAllData() async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All Data'),
        content: const Text(
          'This will delete all chat history and settings. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await StorageService.clearAllData();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('All data cleared')),
              );
              _loadSettings();
            },
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            icon: _isSaving
                ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
                : const Icon(Icons.save),
            onPressed: _isSaving ? null : _saveSettings,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'System Prompt',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _systemPromptController,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Enter system prompt for the AI...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Auto-save & Unload',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Automatically save chat and unload model after inactivity (minutes):',
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _autoSaveController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      hintText: '30',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Data Management',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _clearAllData,
                    icon: const Icon(Icons.delete, color: Colors.red),
                    label: const Text(
                      'Clear All Data',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}