# Apeiron 2.0

A modern, multi-provider AI chat interface built with React and TypeScript. Apeiron allows you to chat with multiple AI models from different providers, compare their responses, and manage your conversations with a beautiful, intuitive interface.

## Features

### 🤖 Multi-Provider Support
- **OpenRouter** - Access to a wide variety of models through OpenRouter
- **OpenAI** - Direct integration with OpenAI's API
- **Anthropic** - Claude models support
- **Google** - Gemini models support
- **Mistral** - Mistral AI models
- **DeepSeek** - DeepSeek models

### 🎯 Model Comparison
- Compare responses from multiple models side-by-side
- Select and enable/disable specific models
- Add custom models from OpenRouter
- Visual indicators for each model's provider

### 💬 Rich Chat Experience
- **Streaming Responses** - Real-time token streaming for faster responses
- **Markdown Rendering** - Beautiful markdown support with syntax highlighting
- **Code Blocks** - Download code files directly from chat responses
- **File Attachments** - Upload images and text files (`.txt`, `.md`, `.csv`, `.json`, `.js`, `.ts`, `.py`, `.html`, `.css`)
- **Voice Input** - Speech-to-text using browser's Web Speech API
- **Image Generation** - Support for models that generate images

### 📁 Organization
- **Projects** - Organize conversations into projects
- **Conversation Management** - Create, rename, delete, and search conversations
- **Drag & Drop** - Drag conversations into projects
- **Local Storage** - All data stored locally in your browser

### 🎨 Customization
- **Dark/Light Theme** - Toggle between themes
- **Custom System Prompts** - Set global system prompts for all models
- **Model Selection** - Choose which models appear in your chat
- **API Key Management** - Secure local storage of API keys

## Getting Started

### Prerequisites

- Node.js 18+ and npm

### Installation

1. Clone the repository:
```bash
git clone <repository-url>
cd "Apeiron 2.0"
```

2. Install dependencies:
```bash
npm install
```

3. Start the development server:
```bash
npm run dev
```

4. Open your browser and navigate to `http://localhost:5173`

### Building for Production

```bash
npm run build
```

The built files will be in the `dist` directory.

### Preview Production Build

```bash
npm run preview
```

## Usage

### Setting Up API Keys

1. Click the **Settings** button in the sidebar
2. Navigate to the **Keys** tab
3. Enter your API keys for the providers you want to use
4. API keys are stored locally in your browser and never sent to any server except the respective AI providers

### Starting a Conversation

1. Click the **+** button next to "Conversations" to create a new chat
2. Select a model from the model picker
3. Type your message or use voice input
4. Press **Enter** to send (or **Shift+Enter** for a new line)

### Comparing Models

1. Click the **Compare** button in the chat input area
2. Select multiple models from the dropdown
3. Send your message to see responses from all selected models side-by-side

### Managing Projects

1. Click the **+** button next to "Projects" to create a new project
2. Drag conversations into projects to organize them
3. Double-click project or conversation names to rename them
4. Hover over items and click the delete icon to remove them

### File Attachments

1. Click the **+** icon in the chat input area
2. Select images or text files to attach
3. Attached files will be sent along with your message
4. Models that support images can analyze attached images

## Supported Models

### Default Models
- Claude Opus 4.5
- Claude Sonnet 4.5
- GPT-5.2 Chat
- DeepSeek R1 0528 (Free)
- Gemini 3 Flash (Preview)
- Gemini 3 Pro (Preview)
- Gemini 2.5 Flash Image
- Gemini 3 Pro Image
- Nano Banana Pro
- GPT-5 Image

### Custom Models
You can add any model from OpenRouter by entering its model ID in the Settings > Models tab.

## Tech Stack

- **React 18** - UI framework
- **TypeScript** - Type safety
- **Vite** - Build tool and dev server
- **Tailwind CSS** - Styling
- **React Markdown** - Markdown rendering
- **Remark GFM** - GitHub Flavored Markdown support

## Project Structure

```
src/
├── App.tsx              # Main application component
├── main.tsx             # Application entry point
├── styles.css           # Global styles
├── lib/
│   ├── utils.ts        # Utility functions
│   └── useLocalStorage.ts  # Local storage hook
```

## Security Notes

⚠️ **Important**: This application stores API keys in your browser's local storage. For production deployments, consider implementing a backend proxy to keep API keys secure. Client-side API keys are visible to users through browser developer tools.

## Browser Compatibility

- Modern browsers with Web Speech API support (Chrome, Edge, Safari)
- Local Storage support required
- ES6+ JavaScript support

## License

[Add your license here]

## Contributing

[Add contribution guidelines here]

## Acknowledgments

Built with modern web technologies and designed for a seamless AI chat experience.
