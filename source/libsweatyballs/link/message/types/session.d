// Generated by the protocol buffer compiler.  DO NOT EDIT!
// source: source/libsweatyballs/link/message/types/protobufs/session.proto

module session;

import google.protobuf;

enum protocVersion = 3014000;

class SessionMessage
{
    @Proto(1) string toPublicKey = protoDefaultValue!string;
    @Proto(2) SessionType type = protoDefaultValue!SessionType;
    @Proto(3) bytes payload = protoDefaultValue!bytes;
}

class DataMessage
{
    @Proto(1) bytes data = protoDefaultValue!bytes;
}

class NewSessionMessage
{
    @Proto(1) string aesKey = protoDefaultValue!string;
}

class SessionAcknowledgement
{
    @Proto(1) string status = protoDefaultValue!string;
    @Proto(2) string sessionID = protoDefaultValue!string;
}

class CloseSessionMessage
{
    @Proto(1) string sessionID = protoDefaultValue!string;
}

enum SessionType
{
    NEW_SESSION = 0,
    SEND_DATA = 1,
    CLOSE_SESSION = 2,
    SESSION_ACK = 3,
}
