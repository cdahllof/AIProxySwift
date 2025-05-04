//
//  OpenAIRealtimeConversationItemCreate.swift
//
//
//  Created by Lou Zell on 10/12/24.
//

import Foundation

/// https://platform.openai.com/docs/api-reference/realtime-client-events/conversation/item/create
public struct OpenAIRealtimeConversationItemCreate: Encodable {
    public let type = "conversation.item.create"
    public let item: Item

    public init(item: Item) {
        self.item = item
    }
}

// MARK: -
public extension OpenAIRealtimeConversationItemCreate {
    struct Item: Encodable {
        public let type = "message"
        public let role: String
        public let content: [Content]

        public init(role: String, audio: String) {
            self.role = role
            self.content = [.init(audio: audio)]
        }
    }
}

// MARK: -
public extension OpenAIRealtimeConversationItemCreate.Item {
    struct Content: Encodable {
        public let type = "input_audio"
        public let audio: String

        public init(audio: String) {
            self.audio = audio
        }
    }
}

public struct OpenAIRealtimeConversationItemCreateText: Encodable {
    public let type = "conversation.item.create"
    public let item: Item
    
    public init(item: Item) {
        self.item = item
    }
}

// MARK: - ConversationItemCreateText.Item
public extension OpenAIRealtimeConversationItemCreateText {
    struct Item: Encodable {
        public let type = "message"
        public let role: String
        let content: [Content]
        
        public init(role: String, text: String) {
            self.role = role
            self.content = [.init(text: text)]
        }
    }
}

// MARK: - ConversationItemCreateText.Item.Content
public extension OpenAIRealtimeConversationItemCreateText.Item {
    struct Content: Encodable {
        public let type =  "input_text"
        public let text: String
        
        public init(text: String) {
            self.text = text
        }
    }
}
