class FriendConnection {
  const FriendConnection({
    required this.id,
    required this.accountId,
    required this.name,
    required this.email,
    required this.status,
    required this.incoming,
  });
  final String id, accountId, name, email, status;
  final bool incoming;
  bool get accepted => status == 'accepted';
  factory FriendConnection.fromJson(Map<String, dynamic> json) =>
      FriendConnection(
        id: json['id'] as String,
        accountId: json['account_id'] as String,
        name: json['name'] as String? ?? json['email'] as String,
        email: json['email'] as String,
        status: json['status'] as String,
        incoming: json['direction'] == 'incoming',
      );
}
