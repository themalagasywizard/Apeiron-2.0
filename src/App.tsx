import { useEffect, useMemo, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { cn } from "./lib/utils";
import { useLocalStorage } from "./lib/useLocalStorage";

interface ISpeechRecognition extends EventTarget {
  continuous: boolean;
  interimResults: boolean;
  lang: string;
  onresult: ((event: { resultIndex: number; results: { length: number; [index: number]: { isFinal: boolean; [index: number]: { transcript: string } } } }) => void) | null;
  onerror: (() => void) | null;
  onend: (() => void) | null;
  start: () => void;
  stop: () => void;
}

declare global {
  interface Window {
    SpeechRecognition: { new (): ISpeechRecognition };
    webkitSpeechRecognition: { new (): ISpeechRecognition };
  }
}

const PROVIDERS = {
  openrouter: {
    id: "openrouter",
    name: "OpenRouter",
    type: "openai" as const,
    baseUrl: "https://openrouter.ai/api/v1",
  },
  openai: {
    id: "openai",
    name: "OpenAI",
    type: "openai" as const,
    baseUrl: "https://api.openai.com/v1",
  },
  anthropic: {
    id: "anthropic",
    name: "Anthropic",
    type: "anthropic" as const,
    baseUrl: "https://api.anthropic.com/v1",
  },
  google: {
    id: "google",
    name: "Google",
    type: "google" as const,
    baseUrl: "https://generativelanguage.googleapis.com/v1beta",
  },
  mistral: {
    id: "mistral",
    name: "Mistral",
    type: "openai" as const,
    baseUrl: "https://api.mistral.ai/v1",
  },
  deepseek: {
    id: "deepseek",
    name: "DeepSeek",
    type: "openai" as const,
    baseUrl: "https://api.deepseek.com/v1",
  },
} as const;

type ProviderId = keyof typeof PROVIDERS;

type ModelItem = {
  id: string;
  label: string;
  providerId: ProviderId;
  description?: string;
  supportsImages?: boolean;
};

const MODEL_OPTIONS: ModelItem[] = [
  { id: "openrouter/anthropic/claude-opus-4.5", label: "Claude Opus 4.5", providerId: "openrouter" },
  { id: "openrouter/anthropic/claude-sonnet-4.5", label: "Claude Sonnet 4.5", providerId: "openrouter" },
  { id: "openrouter/openai/gpt-5.2-chat", label: "GPT-5.2 Chat", providerId: "openrouter" },
  { id: "openrouter/deepseek/deepseek-r1-0528:free", label: "DeepSeek R1 0528 (Free)", providerId: "openrouter" },
  { id: "openrouter/google/gemini-3-flash-preview", label: "Gemini 3 Flash (Preview)", providerId: "openrouter" },
  { id: "openrouter/google/gemini-3-pro-preview", label: "Gemini 3 Pro (Preview)", providerId: "openrouter" },
  { id: "openrouter/google/gemini-2.5-flash-image", label: "Gemini 2.5 Flash Image", providerId: "openrouter", supportsImages: true },
  { id: "openrouter/google/gemini-3-pro-image-preview", label: "Gemini 3 Pro Image", providerId: "openrouter", supportsImages: true },
  { id: "openrouter/google/nano-banana-pro", label: "Nano Banana Pro", providerId: "openrouter", supportsImages: true },
  { id: "openrouter/openai/gpt-5-image", label: "GPT-5 Image", providerId: "openrouter", supportsImages: true },
];

type Attachment = {
  name: string;
  type: string;
  dataUrl: string;
};

type SourceCitation = {
  url: string;
  title?: string;
  content?: string;
};

type Message = {
  id: string;
  role: "user" | "assistant";
  content: string;
  createdAt: number;
  modelId?: string;
  providerId?: ProviderId;
  isStreaming?: boolean;
  images?: string[];
  attachments?: Attachment[];
  sources?: SourceCitation[];
};

type Conversation = {
  id: string;
  title: string;
  messages: Message[];
  updatedAt: number;
  projectId?: string | null;
};

type Settings = {
  keys: Record<ProviderId, string>;
  systemPrompt: string;
  colorMode: "dark" | "light";
  theme: "basic" | "matrix" | "shadcn";
  enabledModels: string[];
  customModels?: ModelItem[];
};

type Project = {
  id: string;
  name: string;
};

const defaultSettings: Settings = {
  keys: {
    openrouter: "",
    openai: "",
    anthropic: "",
    google: "",
    mistral: "",
    deepseek: "",
  },
  systemPrompt: "",
  colorMode: "dark",
  theme: "basic",
  enabledModels: MODEL_OPTIONS.map((model) => model.id),
};

const STORAGE_KEYS = {
  settings: "apeiron.settings.v1",
  conversations: "apeiron.conversations.v1",
  activeConversation: "apeiron.activeConversation.v1",
  projects: "apeiron.projects.v1",
};

function uid() {
  return Math.random().toString(36).slice(2, 10);
}

function getModelLabel(modelId: string, models: ModelItem[] = MODEL_OPTIONS) {
  return models.find((model) => model.id === modelId)?.label ?? modelId;
}

function extractSources(annotations: unknown[]): SourceCitation[] {
  if (!Array.isArray(annotations)) return [];
  return annotations.flatMap((annotation) => {
    if (!annotation || typeof annotation !== "object") return [];
    const ann = annotation as Record<string, unknown>;
    const citation = (ann.url_citation ?? ann.urlCitation ?? ann) as Record<string, unknown>;
    const url = typeof citation.url === "string" ? citation.url : typeof ann.url === "string" ? ann.url : "";
    if (!url) return [];
    const title = typeof citation.title === "string" ? citation.title : undefined;
    const content = typeof citation.content === "string" ? citation.content : undefined;
    return [{ url, title, content }];
  });
}

function mergeSources(existing: SourceCitation[] | undefined, incoming: SourceCitation[]) {
  const map = new Map<string, SourceCitation>();
  (existing ?? []).forEach((source) => map.set(source.url, { ...source }));
  incoming.forEach((source) => {
    const current = map.get(source.url);
    if (!current) {
      map.set(source.url, source);
      return;
    }
    map.set(source.url, {
      url: source.url,
      title: current.title ?? source.title,
      content: current.content ?? source.content,
    });
  });
  return Array.from(map.values());
}

function buildContext(messages: Message[], modelId: string, providerId: ProviderId) {
  return messages.filter((message) => {
    if (message.role === "user") return true;
    if (message.role === "assistant" && message.modelId === modelId && message.providerId === providerId) return true;
    return false;
  });
}

async function streamOpenAICompatible(options: {
  apiKey: string;
  baseUrl: string;
  model: string;
  messages: Message[];
  systemPrompt?: string;
  onToken: (token: string) => void;
  onImage?: (url: string) => void;
  onAnnotations?: (annotations: unknown[]) => void;
  supportsImages?: boolean;
  signal?: AbortSignal;
  plugins?: Array<{ id: string; max_results?: number; search_prompt?: string; engine?: "exa" | "native" }>;
}) {
  const payloadMessages = [
    ...(options.systemPrompt
      ? [{ role: "system", content: options.systemPrompt }]
      : []),
    ...options.messages.map((msg) => {
      const hasAttachments = msg.attachments && msg.attachments.length > 0;
      if (!hasAttachments) return { role: msg.role, content: msg.content };
      const parts: Array<{ type: string; text?: string; image_url?: { url: string } }> = [];
      if (msg.content) parts.push({ type: "text", text: msg.content });
      for (const att of msg.attachments!) {
        if (att.type.startsWith("image/")) {
          parts.push({ type: "image_url", image_url: { url: att.dataUrl } });
        } else {
          parts.push({ type: "text", text: `[File: ${att.name}]\n${atob(att.dataUrl.split(",")[1] ?? "")}` });
        }
      }
      return { role: msg.role, content: parts };
    }),
  ];

  const body: Record<string, unknown> = {
    model: options.model,
    messages: payloadMessages,
    stream: true,
  };
  if (options.supportsImages) {
    body.modalities = ["text", "image"];
  }
  if (options.plugins && options.plugins.length) {
    body.plugins = options.plugins;
  }

  const response = await fetch(`${options.baseUrl}/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${options.apiKey}`,
    },
    signal: options.signal,
    body: JSON.stringify(body),
  });

  if (!response.ok || !response.body) {
    const errorText = await response.text();
    throw new Error(errorText || "Request failed");
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder("utf-8");
  let buffer = "";

  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    const parts = buffer.split("\n\n");
    buffer = parts.pop() ?? "";

    for (const part of parts) {
      const line = part.trim();
      if (!line.startsWith("data:")) continue;
      const data = line.replace(/^data:\s*/, "").trim();
      if (data === "[DONE]") return;
      try {
        const json = JSON.parse(data);
        const delta = json.choices?.[0]?.delta?.content;
        if (delta) options.onToken(delta);
        const annotations =
          json.choices?.[0]?.delta?.annotations ??
          json.choices?.[0]?.message?.annotations ??
          json.choices?.[0]?.message?.content?.[0]?.annotations;
        if (annotations && options.onAnnotations) {
          options.onAnnotations(annotations);
        }
        const images = json.choices?.[0]?.delta?.images ?? json.choices?.[0]?.message?.images;
        if (images && options.onImage) {
          for (const img of images) {
            const url = img?.image_url?.url ?? img?.url;
            if (url) options.onImage(url);
          }
        }
      } catch {
        // Ignore parse errors
      }
    }
  }
}

async function streamAnthropic(options: {
  apiKey: string;
  model: string;
  messages: Message[];
  systemPrompt?: string;
  onToken: (token: string) => void;
  signal?: AbortSignal;
}) {
  const response = await fetch(`${PROVIDERS.anthropic.baseUrl}/messages`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": options.apiKey,
      "anthropic-version": "2023-06-01",
    },
    signal: options.signal,
    body: JSON.stringify({
      model: options.model,
      max_tokens: 1024,
      system: options.systemPrompt || undefined,
      messages: options.messages.map((msg) => ({ role: msg.role, content: msg.content })),
      stream: true,
    }),
  });

  if (!response.ok || !response.body) {
    const errorText = await response.text();
    throw new Error(errorText || "Request failed");
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder("utf-8");
  let buffer = "";

  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    const events = buffer.split("\n\n");
    buffer = events.pop() ?? "";

    for (const event of events) {
      const lines = event.split("\n");
      const dataLine = lines.find((line) => line.startsWith("data:"));
      if (!dataLine) continue;
      const data = dataLine.replace(/^data:\s*/, "").trim();
      try {
        const json = JSON.parse(data);
        if (json.type === "content_block_delta") {
          const text = json.delta?.text;
          if (text) options.onToken(text);
        }
      } catch {
        // Ignore parse errors
      }
    }
  }
}

async function streamGoogle(options: {
  apiKey: string;
  model: string;
  messages: Message[];
  systemPrompt?: string;
  onToken: (token: string) => void;
  signal?: AbortSignal;
}) {
  const systemInstruction = options.systemPrompt
    ? { parts: [{ text: options.systemPrompt }] }
    : undefined;

  const contents = options.messages.map((msg) => ({
    role: msg.role === "assistant" ? "model" : "user",
    parts: [{ text: msg.content }],
  }));

  const response = await fetch(
    `${PROVIDERS.google.baseUrl}/models/${options.model}:streamGenerateContent?alt=sse&key=${options.apiKey}`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      signal: options.signal,
      body: JSON.stringify({
        contents,
        systemInstruction,
      }),
    }
  );

  if (!response.ok || !response.body) {
    const errorText = await response.text();
    throw new Error(errorText || "Request failed");
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder("utf-8");
  let buffer = "";

  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    const parts = buffer.split("\n\n");
    buffer = parts.pop() ?? "";

    for (const part of parts) {
      const line = part.trim();
      if (!line.startsWith("data:")) continue;
      const data = line.replace(/^data:\s*/, "").trim();
      try {
        const json = JSON.parse(data);
        const text = json.candidates?.[0]?.content?.parts?.[0]?.text;
        if (text) options.onToken(text);
      } catch {
        // Ignore parse errors
      }
    }
  }
}

async function streamProviderResponse(options: {
  providerId: ProviderId;
  apiKey: string;
  model: string;
  messages: Message[];
  systemPrompt?: string;
  onToken: (token: string) => void;
  onImage?: (url: string) => void;
  onAnnotations?: (annotations: unknown[]) => void;
  supportsImages?: boolean;
  signal?: AbortSignal;
  plugins?: Array<{ id: string; max_results?: number; search_prompt?: string; engine?: "exa" | "native" }>;
}) {
  if (!options.apiKey) {
    throw new Error("Missing API key for provider.");
  }

  const provider = PROVIDERS[options.providerId];

  if (provider.type === "openai") {
    return streamOpenAICompatible({
      apiKey: options.apiKey,
      baseUrl: provider.baseUrl,
      model: options.model,
      messages: options.messages,
      systemPrompt: options.systemPrompt,
      onToken: options.onToken,
      onImage: options.onImage,
      onAnnotations: options.onAnnotations,
      supportsImages: options.supportsImages,
      signal: options.signal,
      plugins: options.plugins,
    });
  }

  if (provider.type === "anthropic") {
    return streamAnthropic({
      apiKey: options.apiKey,
      model: options.model,
      messages: options.messages,
      systemPrompt: options.systemPrompt,
      onToken: options.onToken,
      signal: options.signal,
    });
  }

  if (provider.type === "google") {
    return streamGoogle({
      apiKey: options.apiKey,
      model: options.model,
      messages: options.messages,
      systemPrompt: options.systemPrompt,
      onToken: options.onToken,
      signal: options.signal,
    });
  }
}

function parseCodeMeta(className?: string, meta?: string) {
  let language = "";
  let filename = "";
  if (className?.startsWith("language-")) {
    const info = className.replace("language-", "");
    if (info.includes(":")) {
      const [lang, file] = info.split(":");
      language = lang || "";
      filename = file || "";
    } else {
      if (info.includes(".")) {
        filename = info;
        language = info.split(".").pop() || "";
      } else {
        language = info;
      }
    }
  }
  if (!filename && meta) {
    const match = meta.match(/file=([^\s]+)/);
    if (match) filename = match[1];
  }
  return { language, filename };
}

function ModelPicker({
  selectedModel,
  setSelectedModel,
  compareMode,
  selectedCompareModels,
  setSelectedCompareModels,
  models,
}: {
  selectedModel: ModelItem | null;
  setSelectedModel: (model: ModelItem) => void;
  compareMode: boolean;
  selectedCompareModels: string[];
  setSelectedCompareModels: (models: string[]) => void;
  models: ModelItem[];
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    function onClick(event: MouseEvent) {
      if (!ref.current) return;
      if (!ref.current.contains(event.target as Node)) setOpen(false);
    }
    document.addEventListener("mousedown", onClick);
    return () => document.removeEventListener("mousedown", onClick);
  }, []);

  const grouped = useMemo(() => {
    return models.reduce<Record<ProviderId, ModelItem[]>>((acc, model) => {
      acc[model.providerId].push(model);
      return acc;
    }, {
      openrouter: [],
      openai: [],
      anthropic: [],
      google: [],
      mistral: [],
      deepseek: [],
    });
  }, [models]);

  const groupedEntries = Object.entries(grouped).filter((entry) => entry[1].length > 0);

  return (
    <div className="relative" ref={ref}>
      <button
        type="button"
        className="flex items-center gap-2 bg-[var(--accent-soft)] px-3 py-1.5 rounded-full border border-[var(--border-subtle)] cursor-pointer hover:bg-[var(--hover-bg)] transition-colors"
        onClick={() => setOpen((prev) => !prev)}
      >
        <span className="text-[12px] font-medium text-[var(--text-muted)]">
          {compareMode ? "Compare models" : selectedModel?.label ?? "No models"}
        </span>
        <span className="material-symbols-outlined text-[14px] text-[var(--text-icon)]">expand_more</span>
      </button>
      {open && (
        <div className="absolute right-0 bottom-12 w-72 rounded-2xl border border-[var(--border-subtle)] bg-[var(--surface-1)] shadow-2xl p-2 text-sm">
          {models.length === 0 ? (
            <div className="px-3 py-4 text-xs text-[var(--text-secondary)]">
              Add an API key and enable models in Settings.
            </div>
          ) : (
            groupedEntries.map(([providerId, models]) => (
              <div key={providerId} className="mb-2">
                <p className="px-2 py-1 text-[10px] font-bold text-[var(--text-secondary)] uppercase tracking-[0.1em]">
                  {PROVIDERS[providerId as ProviderId].name}
                </p>
                <div className="space-y-1">
                  {models.map((model) => (
                    <button
                      key={model.id}
                      type="button"
                      className={cn(
                        "w-full flex items-center gap-2 px-2 py-2 rounded-lg text-left transition-colors",
                        compareMode
                          ? "text-[var(--text-muted)] hover:bg-[var(--hover-bg)]"
                          : selectedModel?.id === model.id
                          ? "bg-[var(--active-bg)] text-[var(--text-primary)]"
                          : "text-[var(--text-muted)] hover:bg-[var(--hover-bg)]"
                      )}
                      onClick={() => {
                        if (compareMode) {
                          setSelectedCompareModels(
                            selectedCompareModels.includes(model.id)
                              ? selectedCompareModels.filter((id) => id !== model.id)
                              : [...selectedCompareModels, model.id]
                          );
                        } else {
                          setSelectedModel(model);
                          setOpen(false);
                        }
                      }}
                    >
                      {compareMode ? (
                        <span
                          className={cn(
                            "inline-flex size-4 items-center justify-center rounded border border-[var(--border-subtle)]",
                            selectedCompareModels.includes(model.id) && "bg-[var(--text-primary)] text-[var(--bg-main)]"
                          )}
                        >
                          {selectedCompareModels.includes(model.id) && "✓"}
                        </span>
                      ) : null}
                      <span className="text-xs text-[var(--text-muted)]">{model.label}</span>
                    </button>
                  ))}
                </div>
              </div>
            ))
          )}
        </div>
      )}
    </div>
  );
}

export default function App() {
  const [settings, setSettings] = useLocalStorage<Settings>(STORAGE_KEYS.settings, defaultSettings);
  const [conversations, setConversations] = useLocalStorage<Conversation[]>(STORAGE_KEYS.conversations, []);
  const [activeConversationId, setActiveConversationId] = useLocalStorage<string | null>(
    STORAGE_KEYS.activeConversation,
    null
  );
  const [projects, setProjects] = useLocalStorage<Project[]>(STORAGE_KEYS.projects, []);
  const [showSettings, setShowSettings] = useState(false);
  const [showSidebar, setShowSidebar] = useState(true);
  const [webSearchEnabled, setWebSearchEnabled] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editingName, setEditingName] = useState("");
  const [input, setInput] = useState("");
  const [compareMode, setCompareMode] = useState(false);
  const [selectedModelId, setSelectedModelId] = useState(MODEL_OPTIONS[0].id);
  const [selectedCompareModels, setSelectedCompareModels] = useState<string[]>([MODEL_OPTIONS[0].id]);
  const [search, setSearch] = useState("");
  const [settingsTab, setSettingsTab] = useState<"keys" | "models" | "appearance">("keys");
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [isListening, setIsListening] = useState(false);
  const [customModelInput, setCustomModelInput] = useState("");
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const recognitionRef = useRef<ISpeechRecognition | null>(null);
  const abortControllersRef = useRef<Map<string, AbortController>>(new Map());
  const themeOptions = [
    {
      id: "basic" as const,
      name: "Basic (Default)",
      description: "Crisp neutrals with balanced contrast for long sessions.",
      preview: "linear-gradient(135deg, #f4f4f5 0%, #e4e4e7 50%, #0f0f0f 100%)",
    },
    {
      id: "matrix" as const,
      name: "Matrix",
      description: "High-contrast terminal greens with cinematic glow.",
      preview: "linear-gradient(135deg, #020b06 0%, #0b3b1d 55%, #b7ff3c 100%)",
    },
    {
      id: "shadcn" as const,
      name: "Shadcn",
      description: "Muted slate with refined surfaces and modern depth.",
      preview: "linear-gradient(135deg, #f8fafc 0%, #dbe2ea 50%, #0f172a 100%)",
    },
  ];
  const isMatrixTheme = settings.theme === "matrix";
  const matrixRain = useMemo(() => {
    let seed = 42;
    const rand = () => {
      seed = (seed * 1664525 + 1013904223) % 4294967296;
      return seed / 4294967296;
    };
    const glyphs = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ$+-*/=<>[]{}";
    return Array.from({ length: 34 }, (_, index) => {
      const length = 42 + Math.floor(rand() * 36);
      const chars = Array.from({ length }, () => glyphs[Math.floor(rand() * glyphs.length)]).join("\n");
      return {
        id: `column-${index}`,
        left: `${(index / 34) * 100}%`,
        duration: `${12 + rand() * 10}s`,
        delay: `${-rand() * 20}s`,
        size: `${13 + rand() * 7}px`,
        chars,
      };
    });
  }, []);

  const allModels = useMemo(() => {
    const custom = Array.isArray(settings.customModels) ? settings.customModels : [];
    return [...MODEL_OPTIONS, ...custom];
  }, [settings.customModels]);

  const enabledModels = useMemo(() => {
    const enabled = Array.isArray(settings.enabledModels)
      ? settings.enabledModels
      : allModels.map((model) => model.id);
    return allModels.filter((model) => enabled.includes(model.id));
  }, [settings.enabledModels, allModels]);

  const availableModels = useMemo(() => {
    return enabledModels.filter((model) => settings.keys[model.providerId]);
  }, [enabledModels, settings.keys]);

  const selectedModel = availableModels.find((model) => model.id === selectedModelId) ?? availableModels[0] ?? null;
  const canUseWebSearch = compareMode
    ? selectedCompareModels.some((modelId) => availableModels.find((m) => m.id === modelId)?.providerId === "openrouter")
    : selectedModel?.providerId === "openrouter";

  useEffect(() => {
    if (!activeConversationId && conversations.length) {
      setActiveConversationId(conversations[0].id);
    }
  }, [activeConversationId, conversations, setActiveConversationId]);

  useEffect(() => {
    const storedTheme = (settings as { theme?: string }).theme;
    const storedMode = (settings as { colorMode?: "dark" | "light" }).colorMode;
    const nextColorMode: "dark" | "light" = storedMode ?? (storedTheme === "light" ? "light" : "dark");
    const nextTheme = storedTheme === "basic" || storedTheme === "matrix" || storedTheme === "shadcn"
      ? storedTheme
      : "basic";
    if (nextColorMode !== settings.colorMode || nextTheme !== settings.theme) {
      setSettings({ ...settings, colorMode: nextColorMode, theme: nextTheme });
    }
  }, [settings, setSettings]);

  useEffect(() => {
    const root = document.documentElement;
    root.classList.toggle("dark", settings.colorMode === "dark");
    root.classList.remove("theme-basic", "theme-matrix", "theme-shadcn");
    root.classList.add(`theme-${settings.theme}`);
  }, [settings.colorMode, settings.theme]);

  useEffect(() => {
    if (settings.theme === "matrix" && settings.colorMode !== "dark") {
      setSettings({ ...settings, colorMode: "dark" });
    }
  }, [settings.theme, settings.colorMode, settings, setSettings]);

  useEffect(() => {
    if (!Array.isArray(settings.enabledModels) || settings.enabledModels.length === 0) {
      setSettings({ ...settings, enabledModels: allModels.map((model) => model.id) });
    }
  }, [settings, setSettings, allModels]);

  useEffect(() => {
    if (!availableModels.find((model) => model.id === selectedModelId) && availableModels.length) {
      setSelectedModelId(availableModels[0].id);
    }
  }, [availableModels, selectedModelId]);

  useEffect(() => {
    setSelectedCompareModels((prev) => prev.filter((modelId) => availableModels.some((m) => m.id === modelId)));
  }, [availableModels]);

  useEffect(() => {
    if (webSearchEnabled && !canUseWebSearch) {
      setWebSearchEnabled(false);
    }
  }, [webSearchEnabled, canUseWebSearch]);

  useEffect(() => {
    if (!textareaRef.current) return;
    textareaRef.current.style.height = "auto";
    textareaRef.current.style.height = `${Math.min(textareaRef.current.scrollHeight, 192)}px`;
  }, [input]);

  const filteredConversations = useMemo(() => {
    if (!search.trim()) return conversations;
    return conversations.filter((conversation) =>
      conversation.title.toLowerCase().includes(search.toLowerCase())
    );
  }, [conversations, search]);

  const activeConversation = conversations.find((conversation) => conversation.id === activeConversationId) ?? null;
  const isStreaming = activeConversation?.messages.some((message) => message.isStreaming) ?? false;

  function createNewChat() {
    const newConversation: Conversation = {
      id: uid(),
      title: `New Chat ${conversations.length + 1}`,
      messages: [],
      updatedAt: Date.now(),
      projectId: null,
    };
    setConversations([newConversation, ...conversations]);
    setActiveConversationId(newConversation.id);
  }

  function deleteChat(id: string) {
    const next = conversations.filter((conversation) => conversation.id !== id);
    setConversations(next);
    if (activeConversationId === id) {
      setActiveConversationId(next[0]?.id ?? null);
    }
  }

  function assignConversationToProject(conversationId: string, projectId: string | null) {
    updateConversation(conversationId, (conversation) => ({
      ...conversation,
      projectId,
      updatedAt: Date.now(),
    }));
  }

  function createProject() {
    const newProject: Project = { id: uid(), name: `Project ${projects.length + 1}` };
    setProjects([...projects, newProject]);
    setEditingId(newProject.id);
    setEditingName(newProject.name);
  }

  function deleteProject(projectId: string) {
    setProjects(projects.filter((p) => p.id !== projectId));
    setConversations((prev) =>
      prev.map((c) => (c.projectId === projectId ? { ...c, projectId: null } : c))
    );
  }

  function renameProject(projectId: string, name: string) {
    const trimmed = name.trim();
    if (!trimmed) return;
    setProjects(projects.map((p) => (p.id === projectId ? { ...p, name: trimmed } : p)));
  }

  function renameConversation(conversationId: string, title: string) {
    const trimmed = title.trim();
    if (!trimmed) return;
    updateConversation(conversationId, (conversation) => ({ ...conversation, title: trimmed }));
  }

  function commitRename() {
    if (!editingId) return;
    const isProject = projects.some((p) => p.id === editingId);
    if (isProject) {
      renameProject(editingId, editingName);
    } else {
      renameConversation(editingId, editingName);
    }
    setEditingId(null);
    setEditingName("");
  }

  function stopStreaming() {
    abortControllersRef.current.forEach((controller) => controller.abort());
    abortControllersRef.current.clear();
    if (!activeConversation) return;
    updateConversation(activeConversation.id, (conversation) => ({
      ...conversation,
      messages: conversation.messages.map((message) =>
        message.isStreaming ? { ...message, isStreaming: false } : message
      ),
      updatedAt: Date.now(),
    }));
  }

  async function copyToClipboard(text: string) {
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      // ignore
    }
  }

  function handleFileSelect(event: React.ChangeEvent<HTMLInputElement>) {
    const files = event.target.files;
    if (!files) return;
    Array.from(files).forEach((file) => {
      const reader = new FileReader();
      reader.onload = () => {
        setAttachments((prev) => [...prev, { name: file.name, type: file.type, dataUrl: reader.result as string }]);
      };
      reader.readAsDataURL(file);
    });
    event.target.value = "";
  }

  function removeAttachment(index: number) {
    setAttachments((prev) => prev.filter((_, i) => i !== index));
  }

  function toggleSpeechRecognition() {
    if (isListening) {
      recognitionRef.current?.stop();
      setIsListening(false);
      return;
    }
    const SpeechRecognitionAPI = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SpeechRecognitionAPI) return;
    const recognition = new SpeechRecognitionAPI();
    recognition.continuous = true;
    recognition.interimResults = true;
    recognition.lang = "en-US";
    let finalTranscript = "";
    recognition.onresult = (event) => {
      let interim = "";
      for (let i = event.resultIndex; i < event.results.length; i++) {
        if (event.results[i].isFinal) {
          finalTranscript += event.results[i][0].transcript;
        } else {
          interim += event.results[i][0].transcript;
        }
      }
      setInput((prev) => {
        const base = prev.replace(/\u200B.*$/, "");
        return finalTranscript ? base + finalTranscript + (interim ? "\u200B" + interim : "") : base + (interim ? "\u200B" + interim : "");
      });
    };
    recognition.onerror = () => setIsListening(false);
    recognition.onend = () => setIsListening(false);
    recognitionRef.current = recognition;
    finalTranscript = "";
    recognition.start();
    setIsListening(true);
  }

  function downloadCode(filename: string, content: string) {
    const blob = new Blob([content], { type: "text/plain;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  }

  function updateConversation(conversationId: string, updater: (conversation: Conversation) => Conversation) {
    setConversations((prev) =>
      prev.map((conversation) => (conversation.id === conversationId ? updater(conversation) : conversation))
    );
  }

  async function sendMessage() {
    if (!activeConversation) {
      createNewChat();
      return;
    }

    const trimmed = input.replace(/\u200B.*$/, "").trim();
    if (!trimmed && attachments.length === 0) return;
    if (availableModels.length === 0) {
      setShowSettings(true);
      setSettingsTab("keys");
      return;
    }

    const baseMessages = activeConversation.messages;
    const currentAttachments = attachments.length > 0 ? [...attachments] : undefined;

    const userMessage: Message = {
      id: uid(),
      role: "user",
      content: trimmed,
      createdAt: Date.now(),
      attachments: currentAttachments,
    };

    setInput("");
    setAttachments([]);

    updateConversation(activeConversation.id, (conversation) => ({
      ...conversation,
      messages: [...conversation.messages, userMessage],
      updatedAt: Date.now(),
      title: conversation.messages.length === 0 ? trimmed.slice(0, 40) : conversation.title,
    }));

    const modelsToRun = compareMode
      ? selectedCompareModels.filter((modelId) => availableModels.some((m) => m.id === modelId))
      : selectedModel
        ? [selectedModel.id]
        : [];

    const tasks = modelsToRun.map(async (modelId) => {
      const model = availableModels.find((m) => m.id === modelId) ?? selectedModel;
      if (!model) return;
      const useWebSearch = webSearchEnabled && model.providerId === "openrouter";
      const requestModel = model.id.startsWith("openrouter/") ? model.id.replace("openrouter/", "") : model.id;
      const controller = new AbortController();
      const assistantMessage: Message = {
        id: uid(),
        role: "assistant",
        content: "",
        createdAt: Date.now(),
        modelId: model.id,
        providerId: model.providerId,
        isStreaming: true,
      };

      abortControllersRef.current.set(assistantMessage.id, controller);

      updateConversation(activeConversation.id, (conversation) => ({
        ...conversation,
        messages: [...conversation.messages, assistantMessage],
        updatedAt: Date.now(),
      }));

      const contextMessages = buildContext([...baseMessages, userMessage], model.id, model.providerId);

      try {
        await streamProviderResponse({
          providerId: model.providerId,
          apiKey: settings.keys[model.providerId],
          model: requestModel,
          messages: contextMessages,
          systemPrompt: settings.systemPrompt,
          onToken: (token) => {
            updateConversation(activeConversation.id, (conversation) => ({
              ...conversation,
              messages: conversation.messages.map((message) =>
                message.id === assistantMessage.id
                  ? {
                      ...message,
                      content: message.content + token,
                      isStreaming: true,
                    }
                  : message
              ),
              updatedAt: Date.now(),
            }));
          },
          onImage: (url) => {
            updateConversation(activeConversation.id, (conversation) => ({
              ...conversation,
              messages: conversation.messages.map((message) =>
                message.id === assistantMessage.id
                  ? {
                      ...message,
                      images: [...(message.images ?? []), url],
                      isStreaming: true,
                    }
                  : message
              ),
              updatedAt: Date.now(),
            }));
          },
          onAnnotations: (annotations) => {
            const incoming = extractSources(annotations);
            if (incoming.length === 0) return;
            updateConversation(activeConversation.id, (conversation) => ({
              ...conversation,
              messages: conversation.messages.map((message) =>
                message.id === assistantMessage.id
                  ? {
                      ...message,
                      sources: mergeSources(message.sources, incoming),
                      isStreaming: true,
                    }
                  : message
              ),
              updatedAt: Date.now(),
            }));
          },
          supportsImages: model.supportsImages,
          signal: controller.signal,
          plugins: useWebSearch ? [{ id: "web" }] : undefined,
        });
      } catch (error) {
        abortControllersRef.current.delete(assistantMessage.id);
        if (error instanceof DOMException && error.name === "AbortError") {
          updateConversation(activeConversation.id, (conversation) => ({
            ...conversation,
            messages: conversation.messages.map((msg) =>
              msg.id === assistantMessage.id ? { ...msg, isStreaming: false } : msg
            ),
            updatedAt: Date.now(),
          }));
          return;
        }
        const message = error instanceof Error ? error.message : "Unknown error";
        updateConversation(activeConversation.id, (conversation) => ({
          ...conversation,
          messages: conversation.messages.map((msg) =>
            msg.id === assistantMessage.id
              ? {
                  ...msg,
                  content: `Error: ${message}`,
                  isStreaming: false,
                }
              : msg
          ),
          updatedAt: Date.now(),
        }));
        return;
      }

      abortControllersRef.current.delete(assistantMessage.id);
      updateConversation(activeConversation.id, (conversation) => ({
        ...conversation,
        messages: conversation.messages.map((message) =>
          message.id === assistantMessage.id ? { ...message, isStreaming: false } : message
        ),
        updatedAt: Date.now(),
      }));
    });

    await Promise.all(tasks);
  }

  return (
    <div className="relative flex h-screen w-full overflow-hidden">
      {showSidebar ? (
        <aside
          className={cn(
            "relative z-10 w-72 h-full flex flex-col border-r border-[var(--border-subtle)] shrink-0 transition-all",
            isMatrixTheme ? "matrix-surface" : "bg-[var(--bg-sidebar)]"
          )}
        >
          <div className="px-6 py-5 flex items-center justify-between">
            <h1 className="text-xl font-semibold tracking-tight text-[var(--text-primary)]">Apeiron</h1>
            <button
              className="text-[var(--text-icon)] hover:text-[var(--text-primary)] transition-colors"
              onClick={() => setShowSidebar(false)}
              aria-label="Hide sidebar"
            >
              <span className="material-symbols-outlined text-[20px]">dock_to_left</span>
            </button>
          </div>
        <div className="px-4 mb-4">
          <div className="relative group">
            <span className="material-symbols-outlined absolute left-3 top-1/2 -translate-y-1/2 text-[18px] text-[var(--text-icon)] group-focus-within:text-[var(--text-primary)] transition-colors">search</span>
            <input
              className="w-full bg-[var(--accent-soft)] border-none rounded-xl py-2 pl-10 pr-4 text-sm text-[var(--text-primary)] placeholder:text-[var(--text-secondary)] focus:ring-1 focus:ring-[var(--border-subtle)] transition-all"
              placeholder="Search"
              type="text"
              value={search}
              onChange={(event) => setSearch(event.target.value)}
            />
          </div>
        </div>
        <div className="flex-1 overflow-y-auto no-scrollbar px-3 space-y-8 mt-2">
          <div>
            <div className="flex items-center justify-between px-3 mb-3">
              <p className="text-[10px] font-bold text-[var(--text-secondary)] uppercase tracking-[0.1em]">Projects</p>
              <button
                className="text-[var(--text-icon)] hover:text-[var(--text-primary)] transition-colors"
                onClick={createProject}
              >
                <span className="material-symbols-outlined text-[16px]">add</span>
              </button>
            </div>
            <div className="space-y-1">
              {projects.map((project) => {
                const projectChats = filteredConversations.filter((c) => c.projectId === project.id);
                return (
                  <div key={project.id}>
                    <div
                      className="group w-full flex items-center gap-3 px-3 py-2 text-sm text-[var(--text-muted)] hover:text-[var(--text-primary)] hover:bg-[var(--hover-bg)] rounded-lg transition-all text-left"
                      onDragOver={(event) => event.preventDefault()}
                      onDrop={(event) => {
                        const conversationId = event.dataTransfer.getData("text/plain");
                        if (conversationId) assignConversationToProject(conversationId, project.id);
                      }}
                    >
                      <span className="material-symbols-outlined text-[18px]">folder</span>
                      {editingId === project.id ? (
                        <input
                          className="flex-1 bg-transparent border-none text-sm text-[var(--text-primary)] outline-none focus:ring-0 p-0"
                          value={editingName}
                          onChange={(event) => setEditingName(event.target.value)}
                          onBlur={commitRename}
                          onKeyDown={(event) => {
                            if (event.key === "Enter") commitRename();
                            if (event.key === "Escape") { setEditingId(null); setEditingName(""); }
                          }}
                          autoFocus
                          onClick={(event) => event.stopPropagation()}
                        />
                      ) : (
                        <span
                          className="truncate flex-1"
                          onDoubleClick={() => { setEditingId(project.id); setEditingName(project.name); }}
                        >
                          {project.name}
                        </span>
                      )}
                      <button
                        className="opacity-0 group-hover:opacity-100 text-[var(--text-icon)] hover:text-red-400 transition-all shrink-0"
                        onClick={(event) => { event.stopPropagation(); deleteProject(project.id); }}
                      >
                        <span className="material-symbols-outlined text-[16px]">delete</span>
                      </button>
                    </div>
                    {projectChats.length > 0 && (
                      <div className="ml-4 space-y-0.5 mt-0.5">
                        {projectChats.map((conversation) => (
                          <div
                            key={conversation.id}
                            className={cn(
                              "group px-3 py-2 text-sm rounded-lg cursor-pointer flex items-center gap-3",
                              conversation.id === activeConversationId
                                ? "bg-[var(--active-bg)] text-[var(--text-primary)]"
                                : "text-[var(--text-muted)] hover:bg-[var(--hover-bg)]"
                            )}
                            onClick={() => setActiveConversationId(conversation.id)}
                            draggable
                            onDragStart={(event) => event.dataTransfer.setData("text/plain", conversation.id)}
                          >
                            <span className="material-symbols-outlined text-[16px] text-[var(--text-icon)]">chat_bubble</span>
                            {editingId === conversation.id ? (
                              <input
                                className="flex-1 bg-transparent border-none text-sm text-[var(--text-primary)] outline-none focus:ring-0 p-0"
                                value={editingName}
                                onChange={(event) => setEditingName(event.target.value)}
                                onBlur={commitRename}
                                onKeyDown={(event) => {
                                  if (event.key === "Enter") commitRename();
                                  if (event.key === "Escape") { setEditingId(null); setEditingName(""); }
                                }}
                                autoFocus
                                onClick={(event) => event.stopPropagation()}
                              />
                            ) : (
                              <span
                                className="truncate flex-1"
                                onDoubleClick={(event) => { event.stopPropagation(); setEditingId(conversation.id); setEditingName(conversation.title); }}
                              >
                                {conversation.title}
                              </span>
                            )}
                            <button
                              className="opacity-0 group-hover:opacity-100 text-[var(--text-icon)] hover:text-red-400 transition-all shrink-0"
                              onClick={(event) => { event.stopPropagation(); deleteChat(conversation.id); }}
                            >
                              <span className="material-symbols-outlined text-[16px]">delete</span>
                            </button>
                          </div>
                        ))}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          </div>
          <div>
            <div className="flex items-center justify-between px-3 mb-3">
              <p className="text-[10px] font-bold text-[var(--text-secondary)] uppercase tracking-[0.1em]">Conversations</p>
              <button
                className="text-[var(--text-icon)] hover:text-[var(--text-primary)] transition-colors"
                onClick={createNewChat}
              >
                <span className="material-symbols-outlined text-[16px]">add</span>
              </button>
            </div>
            <div className="space-y-0.5">
              {filteredConversations.filter((c) => !c.projectId).length === 0 ? (
                <div className="px-3 py-2 text-xs text-[var(--text-secondary)]">No conversations yet.</div>
              ) : (
                filteredConversations.filter((c) => !c.projectId).map((conversation) => (
                  <div
                    key={conversation.id}
                    className={cn(
                      "group px-3 py-2.5 text-sm rounded-lg cursor-pointer flex items-center gap-3",
                      conversation.id === activeConversationId
                        ? "bg-[var(--active-bg)] text-[var(--text-primary)]"
                        : "text-[var(--text-muted)] hover:bg-[var(--hover-bg)]"
                    )}
                    onClick={() => setActiveConversationId(conversation.id)}
                    draggable
                    onDragStart={(event) => event.dataTransfer.setData("text/plain", conversation.id)}
                  >
                    <span className="material-symbols-outlined text-[18px] text-[var(--text-icon)]">chat_bubble</span>
                    {editingId === conversation.id ? (
                      <input
                        className="flex-1 bg-transparent border-none text-sm text-[var(--text-primary)] outline-none focus:ring-0 p-0"
                        value={editingName}
                        onChange={(event) => setEditingName(event.target.value)}
                        onBlur={commitRename}
                        onKeyDown={(event) => {
                          if (event.key === "Enter") commitRename();
                          if (event.key === "Escape") { setEditingId(null); setEditingName(""); }
                        }}
                        autoFocus
                        onClick={(event) => event.stopPropagation()}
                      />
                    ) : (
                      <span
                        className="truncate flex-1"
                        onDoubleClick={(event) => { event.stopPropagation(); setEditingId(conversation.id); setEditingName(conversation.title); }}
                      >
                        {conversation.title}
                      </span>
                    )}
                    <button
                      className="opacity-0 group-hover:opacity-100 text-[var(--text-icon)] hover:text-red-400 transition-all shrink-0"
                      onClick={(event) => { event.stopPropagation(); deleteChat(conversation.id); }}
                    >
                      <span className="material-symbols-outlined text-[16px]">delete</span>
                    </button>
                  </div>
                ))
              )}
            </div>
          </div>
        </div>
        <div className="p-4 border-t border-[var(--border-subtle)]">
          <button
            className="w-full flex items-center gap-3 px-3 py-2 text-sm text-[var(--text-muted)] hover:text-[var(--text-primary)] hover:bg-[var(--hover-bg)] rounded-lg transition-colors"
            onClick={() => setShowSettings(true)}
          >
            <span className="material-symbols-outlined text-[20px]">settings</span>
            <span>Settings</span>
          </button>
        </div>
        </aside>
      ) : null}

      <main
        className={cn(
          "relative z-10 flex-1 flex flex-col overflow-hidden",
          isMatrixTheme ? "matrix-surface" : "bg-[var(--bg-main)]"
        )}
      >
        {!showSidebar ? (
          <button
            className="absolute top-4 left-4 z-20 flex items-center gap-2 rounded-xl border border-[var(--border-subtle)] bg-[var(--surface-1)] px-3 py-2 text-xs text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--hover-bg)] transition-colors"
            onClick={() => setShowSidebar(true)}
            aria-label="Show sidebar"
          >
            <span className="material-symbols-outlined text-[18px]">dock_to_left</span>
            <span>Sidebar</span>
          </button>
        ) : null}
        {isMatrixTheme ? (
          <div className="matrix-rain" aria-hidden="true">
            {matrixRain.map((column) => (
              <span
                key={column.id}
                className="matrix-column"
                style={{
                  left: column.left,
                  animationDuration: column.duration,
                  animationDelay: column.delay,
                  fontSize: column.size,
                }}
              >
                {column.chars}
              </span>
            ))}
          </div>
        ) : null}
        <div className="flex-1 overflow-y-auto pt-8 pb-40">
          <div className="max-w-3xl mx-auto px-6 space-y-12">
            {activeConversation?.messages.length ? (
              <>
                {activeConversation.messages.map((message) => (
                  <div
                    key={message.id}
                    className={cn("flex", message.role === "user" ? "flex-col items-end" : "flex gap-6")}
                  >
                  {message.role === "assistant" ? (
                    <div className="size-8 rounded-full border border-[var(--border-subtle)] bg-white/5 flex items-center justify-center shrink-0 mt-1">
                      <svg className="w-4 h-4 text-white" fill="none" viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg">
                        <path d="M4 4H17.3334V17.3334H30.6666V30.6666H44V44H4V4Z" fill="currentColor"></path>
                      </svg>
                    </div>
                  ) : null}
                  <div className={cn(message.role === "assistant" ? "flex-1 space-y-4 max-w-[90%]" : "max-w-[85%]")}
                  >
                    <div
                      className={cn(
                        message.role === "user"
                          ? "bg-[var(--surface-2)] px-5 py-3 rounded-2xl text-[var(--text-primary)] text-[15px] leading-relaxed border border-[var(--border-subtle)]"
                          : "text-[var(--text-primary)] text-[16px] leading-relaxed space-y-6"
                      )}
                    >
                      {message.role === "assistant" ? (
                        <div className="space-y-4">
                          <div className="flex items-center gap-2 text-xs text-[var(--text-secondary)]">
                            <span className="uppercase tracking-[0.2em] text-[10px]">{message.providerId}</span>
                            {message.modelId ? (
                              <span className="px-2 py-0.5 rounded-full bg-[var(--accent-soft)] border border-[var(--border-subtle)]">
                                {getModelLabel(message.modelId, allModels)}
                              </span>
                            ) : null}
                            {message.isStreaming ? <span className="text-[10px] text-[var(--text-secondary)]">Streaming...</span> : null}
                          </div>
                          <ReactMarkdown
                            remarkPlugins={[remarkGfm]}
                            className="answer-markdown prose max-w-none dark:prose-invert prose-p:leading-relaxed prose-p:my-4 prose-ol:pl-5 prose-ul:pl-5 prose-li:my-2 prose-li:marker:text-[var(--text-secondary)] prose-hr:my-6 prose-strong:text-[var(--text-primary)] prose-code:text-[var(--text-primary)] prose-code:bg-[var(--accent-soft)] prose-code:px-1.5 prose-code:py-0.5 prose-code:rounded"
                            components={{
                              p({ children, ...props }) {
                                return <div {...props}>{children}</div>;
                              },
                              code({ className, children, node, ...props }) {
                                const content = String(children).replace(/\n$/, "");
                                if (!className) {
                                  return (
                                    <code className={className} {...props}>
                                      {children}
                                    </code>
                                  );
                                }
                                const meta = (node as { data?: { meta?: string } })?.data?.meta;
                                const { language, filename } = parseCodeMeta(className, meta);
                                return (
                                  <div className="my-5 rounded-2xl border border-[var(--border-subtle)] bg-[var(--surface-2)] overflow-hidden">
                                    <div className="flex items-center justify-between px-3 py-2 text-xs text-[var(--text-secondary)] border-b border-[var(--border-subtle)] bg-[var(--accent-soft)]">
                                      <div className="flex items-center gap-2">
                                        <span className="uppercase tracking-[0.2em] text-[10px]">{language || "code"}</span>
                                        {filename ? (
                                          <span className="px-2 py-0.5 rounded-full bg-[var(--hover-bg)] text-[10px] text-[var(--text-muted)]">
                                            {filename}
                                          </span>
                                        ) : null}
                                      </div>
                                      <div className="flex items-center gap-2">
                                        {filename ? (
                                          <button
                                            className="px-2 py-1 rounded-lg bg-[var(--hover-bg)] hover:bg-[var(--active-bg)] text-[10px]"
                                            onClick={() => downloadCode(filename, content)}
                                            type="button"
                                          >
                                            Download
                                          </button>
                                        ) : null}
                                        <button
                                          className="px-2 py-1 rounded-lg bg-[var(--hover-bg)] hover:bg-[var(--active-bg)] text-[10px]"
                                          onClick={() => copyToClipboard(content)}
                                          type="button"
                                        >
                                          Copy
                                        </button>
                                      </div>
                                    </div>
                                    <pre className="p-4 overflow-x-auto text-sm text-[var(--text-primary)]">
                                      <code className={className} {...props}>
                                        {content}
                                      </code>
                                    </pre>
                                  </div>
                                );
                              },
                            }}
                          >
                            {message.content || ""}
                          </ReactMarkdown>
                          {message.sources && message.sources.length > 0 ? (
                            <div className="mt-4 rounded-2xl border border-[var(--border-subtle)] bg-[var(--surface-2)] px-4 py-3">
                              <div className="text-[10px] uppercase tracking-[0.2em] text-[var(--text-secondary)]">
                                Sources
                              </div>
                              <div className="mt-2 grid grid-cols-1 gap-2 md:grid-cols-2">
                                {message.sources.map((source) => {
                                  let host = "";
                                  try {
                                    host = new URL(source.url).hostname.replace(/^www\./, "");
                                  } catch {
                                    host = source.url;
                                  }
                                  return (
                                    <a
                                      key={source.url}
                                      href={source.url}
                                      target="_blank"
                                      rel="noreferrer"
                                      className="rounded-xl border border-[var(--border-subtle)] bg-[var(--surface-1)] px-3 py-2 text-left transition-colors hover:bg-[var(--hover-bg)]"
                                    >
                                      <div className="text-[11px] text-[var(--text-secondary)]">{host}</div>
                                      <div className="text-sm text-[var(--text-primary)] break-words">
                                        {source.title || source.url}
                                      </div>
                                    </a>
                                  );
                                })}
                              </div>
                            </div>
                          ) : null}
                          {message.images && message.images.length > 0 ? (
                            <div className="flex flex-wrap gap-3 mt-4">
                              {message.images.map((url, index) => (
                                <a
                                  key={index}
                                  href={url}
                                  target="_blank"
                                  rel="noopener noreferrer"
                                  className="block"
                                >
                                  <img
                                    src={url}
                                    alt={`Generated image ${index + 1}`}
                                    className="rounded-2xl border border-[var(--border-subtle)] max-w-full max-h-[512px] object-contain"
                                  />
                                </a>
                              ))}
                            </div>
                          ) : null}
                        </div>
                      ) : (
                        <>
                          {message.attachments && message.attachments.length > 0 ? (
                            <div className="flex flex-wrap gap-2 mb-2">
                              {message.attachments.map((att, index) =>
                                att.type.startsWith("image/") ? (
                                  <img key={index} src={att.dataUrl} alt={att.name} className="h-40 max-w-full object-contain rounded-xl" />
                                ) : (
                                  <div key={index} className="flex items-center gap-2 px-3 py-1.5 rounded-lg bg-[var(--accent-soft)] border border-[var(--border-subtle)]">
                                    <span className="material-symbols-outlined text-[16px] text-[var(--text-icon)]">description</span>
                                    <span className="text-xs text-[var(--text-muted)]">{att.name}</span>
                                  </div>
                                )
                              )}
                            </div>
                          ) : null}
                          {message.content}
                        </>
                      )}
                    </div>
                    {message.role === "assistant" ? (
                      <div className="flex items-center gap-4 pt-4 border-t border-[var(--border-subtle)]">
                        <button
                          className="text-[var(--text-icon)] hover:text-[var(--text-primary)] transition-colors"
                          onClick={() => copyToClipboard(message.content)}
                        >
                          <span className="material-symbols-outlined text-[18px]">content_copy</span>
                        </button>
                        <button className="text-[var(--text-icon)] hover:text-[var(--text-primary)] transition-colors">
                          <span className="material-symbols-outlined text-[18px]">refresh</span>
                        </button>
                        <div className="flex items-center gap-2 ml-auto">
                          <button className="text-[var(--text-icon)] hover:text-[var(--text-primary)] transition-colors">
                            <span className="material-symbols-outlined text-[18px]">thumb_up</span>
                          </button>
                          <button className="text-[var(--text-icon)] hover:text-[var(--text-primary)] transition-colors">
                            <span className="material-symbols-outlined text-[18px]">thumb_down</span>
                          </button>
                        </div>
                      </div>
                    ) : null}
                  </div>
                  </div>
                ))}
                <div className="h-36" />
              </>
            ) : (
              <div className="text-center text-[var(--text-secondary)] text-sm mt-12">Start a new chat to see messages here.</div>
            )}
          </div>
        </div>

        <footer className="absolute bottom-0 left-0 right-0 p-6 bg-gradient-to-t from-[var(--bg-main)] via-[var(--bg-main)] to-transparent pointer-events-none">
          <div className="max-w-3xl mx-auto pointer-events-auto">
            <div className="glass-chat-bar rounded-[26px] p-2 flex flex-col shadow-2xl transition-all focus-within:ring-1 focus-within:ring-[var(--border-subtle)]">
              <input
                ref={fileInputRef}
                type="file"
                className="hidden"
                multiple
                accept="image/*,.txt,.md,.csv,.json,.js,.ts,.py,.html,.css"
                onChange={handleFileSelect}
              />
              {attachments.length > 0 ? (
                <div className="flex flex-wrap gap-2 px-4 pt-3 pb-1">
                  {attachments.map((att, index) => (
                    <div key={index} className="relative group/att">
                      {att.type.startsWith("image/") ? (
                        <img src={att.dataUrl} alt={att.name} className="h-16 w-16 object-cover rounded-xl border border-[var(--border-subtle)]" />
                      ) : (
                        <div className="h-16 px-3 flex items-center gap-2 rounded-xl border border-[var(--border-subtle)] bg-[var(--accent-soft)]">
                          <span className="material-symbols-outlined text-[18px] text-[var(--text-icon)]">description</span>
                          <span className="text-xs text-[var(--text-muted)] max-w-[100px] truncate">{att.name}</span>
                        </div>
                      )}
                      <button
                        className="absolute -top-1.5 -right-1.5 size-5 rounded-full bg-[var(--surface-1)] border border-[var(--border-subtle)] flex items-center justify-center opacity-0 group-hover/att:opacity-100 transition-opacity"
                        onClick={() => removeAttachment(index)}
                      >
                        <span className="material-symbols-outlined text-[12px] text-[var(--text-icon)]">close</span>
                      </button>
                    </div>
                  ))}
                </div>
              ) : null}
              <textarea
                ref={textareaRef}
                className="w-full bg-transparent border-none text-[var(--text-primary)] focus:ring-0 resize-none px-4 py-3 text-[16px] placeholder:text-[var(--text-secondary)] min-h-[60px] max-h-48"
                placeholder="Message Apeiron..."
                rows={1}
                value={input}
                onChange={(event) => setInput(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter" && !event.shiftKey) {
                    event.preventDefault();
                    if ((input.trim() || attachments.length > 0) && (availableModels.length > 0 || isStreaming)) {
                      isStreaming ? stopStreaming() : sendMessage();
                    }
                  }
                }}
              />
              <div className="flex items-center justify-between px-2 pb-1.5">
                <div className="flex items-center gap-1">
                  <button
                    className="p-2 text-[var(--text-icon)] hover:text-[var(--text-primary)] transition-colors rounded-full hover:bg-[var(--hover-bg)]"
                    onClick={() => fileInputRef.current?.click()}
                  >
                    <span className="material-symbols-outlined text-[20px]">add_circle</span>
                  </button>
                  <button
                    className={cn(
                      "p-2 transition-colors rounded-full",
                      isListening
                        ? "text-red-500 bg-red-500/10 hover:bg-red-500/20"
                        : "text-[var(--text-icon)] hover:text-[var(--text-primary)] hover:bg-[var(--hover-bg)]"
                    )}
                    onClick={toggleSpeechRecognition}
                  >
                    <span className="material-symbols-outlined text-[20px]">{isListening ? "mic" : "mic"}</span>
                  </button>
                </div>
                <div className="flex items-center gap-3">
                  <button
                    type="button"
                    className={cn(
                      "size-8 flex items-center justify-center rounded-full border transition-colors",
                      webSearchEnabled
                        ? "bg-white text-black border-white"
                        : "bg-[var(--accent-soft)] text-[var(--text-muted)] border-[var(--border-subtle)] hover:bg-[var(--hover-bg)]",
                      !canUseWebSearch && "opacity-40 cursor-not-allowed"
                    )}
                    onClick={() => {
                      if (!canUseWebSearch) return;
                      setWebSearchEnabled((prev) => !prev);
                    }}
                    title={canUseWebSearch ? "Web search" : "Web search is available for OpenRouter models"}
                    aria-pressed={webSearchEnabled}
                    aria-label="Toggle web search"
                  >
                    <span className="material-symbols-outlined text-[18px] leading-none">language</span>
                  </button>
                  <button
                    type="button"
                    className={cn(
                      "text-[12px] font-medium px-3 py-1.5 rounded-full border",
                      compareMode
                        ? "bg-white text-black border-white"
                        : "bg-[var(--accent-soft)] text-[var(--text-muted)] border-[var(--border-subtle)] hover:bg-[var(--hover-bg)]"
                    )}
                    onClick={() => setCompareMode((prev) => !prev)}
                  >
                    Compare
                  </button>
                  <ModelPicker
                    selectedModel={selectedModel}
                    setSelectedModel={(model) => setSelectedModelId(model.id)}
                    compareMode={compareMode}
                    selectedCompareModels={selectedCompareModels}
                    setSelectedCompareModels={(models) =>
                    setSelectedCompareModels(models.length ? models : (selectedModel ? [selectedModel.id] : []))
                  }
                    models={availableModels}
                  />
                  <button
                    className="size-8 bg-white text-black rounded-full flex items-center justify-center hover:bg-slate-200 transition-colors disabled:opacity-30"
                    onClick={isStreaming ? stopStreaming : sendMessage}
                    disabled={((!input.trim() && attachments.length === 0) || availableModels.length === 0) && !isStreaming}
                  >
                    {isStreaming ? (
                      <div className="size-3.5 rounded-[3px] bg-current" />
                    ) : (
                      <span className="material-symbols-outlined text-[20px] font-bold">arrow_upward</span>
                    )}
                  </button>
                </div>
              </div>
            </div>
            <div className="mt-3 text-center">
              <p className="text-[10px] text-[var(--text-secondary)] font-medium tracking-wide">
                Apeiron may provide inaccurate information. Verify critical facts.
              </p>
            </div>
          </div>
        </footer>
      </main>

      {showSettings ? (
        <div className="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50">
          <div className="w-full max-w-2xl bg-[var(--surface-1)] border border-[var(--border-subtle)] rounded-3xl p-6 shadow-2xl">
            <div className="flex items-center justify-between mb-6">
              <div>
                <h2 className="text-lg font-semibold text-[var(--text-primary)]">Settings</h2>
                <p className="text-xs text-[var(--text-secondary)]">API keys are stored locally in your browser.</p>
              </div>
              <button className="text-[var(--text-icon)] hover:text-[var(--text-primary)]" onClick={() => setShowSettings(false)}>
                <span className="material-symbols-outlined">close</span>
              </button>
            </div>

            <div className="flex items-center gap-2 border border-[var(--border-subtle)] rounded-2xl p-1 mb-6 bg-[var(--accent-soft)]">
              {[
                { id: "keys", label: "Keys" },
                { id: "models", label: "Models" },
                { id: "appearance", label: "Appearance" },
              ].map((tab) => (
                <button
                  key={tab.id}
                  className={cn(
                    "flex-1 text-sm py-2 rounded-xl transition-colors",
                    settingsTab === tab.id ? "bg-white text-black" : "text-[var(--text-muted)] hover:bg-[var(--hover-bg)]"
                  )}
                  onClick={() => setSettingsTab(tab.id as typeof settingsTab)}
                >
                  {tab.label}
                </button>
              ))}
            </div>

            {settingsTab === "keys" ? (
              <>
                <div className="grid grid-cols-1 gap-4">
                  {Object.entries(PROVIDERS).map(([providerId, provider]) => (
                    <div key={providerId} className="flex items-center gap-4">
                      <div className="w-32 text-sm text-[var(--text-muted)]">{provider.name}</div>
                      <input
                        type="password"
                        className="flex-1 bg-[var(--accent-soft)] border border-[var(--border-subtle)] rounded-xl px-3 py-2 text-sm text-[var(--text-primary)] focus:ring-1 focus:ring-[var(--border-subtle)]"
                        placeholder={`${provider.name} API key`}
                        value={settings.keys[providerId as ProviderId]}
                        onChange={(event) =>
                          setSettings({
                            ...settings,
                            keys: { ...settings.keys, [providerId]: event.target.value },
                          })
                        }
                      />
                    </div>
                  ))}
                </div>

                <div className="mt-6">
                  <label className="text-sm text-[var(--text-muted)]">Global System Prompt</label>
                  <textarea
                    className="mt-2 w-full bg-[var(--accent-soft)] border border-[var(--border-subtle)] rounded-xl px-3 py-2 text-sm text-[var(--text-primary)] focus:ring-1 focus:ring-[var(--border-subtle)] min-h-[120px]"
                    placeholder="Define a global system prompt for all models..."
                    value={settings.systemPrompt}
                    onChange={(event) => setSettings({ ...settings, systemPrompt: event.target.value })}
                  />
                </div>
              </>
            ) : null}

            {settingsTab === "models" ? (
              <div className="space-y-4">
                <p className="text-xs text-[var(--text-secondary)]">
                  Choose which models appear in the selector. Only models with an API key will show in the chat.
                </p>
                <div className="flex gap-2">
                  <input
                    className="flex-1 bg-[var(--accent-soft)] border border-[var(--border-subtle)] rounded-xl px-3 py-2 text-sm text-[var(--text-primary)] placeholder:text-[var(--text-secondary)] focus:ring-1 focus:ring-[var(--border-subtle)]"
                    placeholder="e.g. google/gemini-2.5-pro or openai/gpt-5"
                    value={customModelInput}
                    onChange={(event) => setCustomModelInput(event.target.value)}
                    onKeyDown={(event) => {
                      if (event.key === "Enter") {
                        const tag = customModelInput.trim();
                        if (!tag) return;
                        const fullId = `openrouter/${tag}`;
                        if (allModels.some((m) => m.id === fullId)) { setCustomModelInput(""); return; }
                        const label = tag.split("/").pop()?.replace(/[-_]/g, " ").replace(/\b\w/g, (c) => c.toUpperCase()) ?? tag;
                        const newModel: ModelItem = { id: fullId, label, providerId: "openrouter" };
                        setSettings({
                          ...settings,
                          customModels: [...(settings.customModels ?? []), newModel],
                          enabledModels: [...settings.enabledModels, fullId],
                        });
                        setCustomModelInput("");
                      }
                    }}
                  />
                  <button
                    className="px-3 py-2 rounded-xl bg-white text-black text-sm font-semibold hover:bg-slate-200 transition-colors"
                    onClick={() => {
                      const tag = customModelInput.trim();
                      if (!tag) return;
                      const fullId = `openrouter/${tag}`;
                      if (allModels.some((m) => m.id === fullId)) { setCustomModelInput(""); return; }
                      const label = tag.split("/").pop()?.replace(/[-_]/g, " ").replace(/\b\w/g, (c) => c.toUpperCase()) ?? tag;
                      const newModel: ModelItem = { id: fullId, label, providerId: "openrouter" };
                      setSettings({
                        ...settings,
                        customModels: [...(settings.customModels ?? []), newModel],
                        enabledModels: [...settings.enabledModels, fullId],
                      });
                      setCustomModelInput("");
                    }}
                  >
                    <span className="material-symbols-outlined text-[18px]">add</span>
                  </button>
                </div>
                <div className="grid grid-cols-1 gap-2 max-h-[320px] overflow-y-auto">
                  {allModels.map((model) => {
                    const isCustom = (settings.customModels ?? []).some((m) => m.id === model.id);
                    return (
                      <label
                        key={model.id}
                        className="flex items-center justify-between rounded-xl border border-[var(--border-subtle)] bg-[var(--accent-soft)] px-3 py-2 text-sm text-[var(--text-primary)]"
                      >
                        <div className="flex items-center gap-2 min-w-0">
                          <div className="min-w-0">
                            <div className="text-[var(--text-primary)] truncate">{model.label}</div>
                            <div className="text-[10px] text-[var(--text-secondary)] truncate">{model.id}</div>
                          </div>
                        </div>
                        <div className="flex items-center gap-2 shrink-0">
                          {isCustom ? (
                            <button
                              className="text-[var(--text-icon)] hover:text-red-400 transition-colors"
                              onClick={(event) => {
                                event.preventDefault();
                                setSettings({
                                  ...settings,
                                  customModels: (settings.customModels ?? []).filter((m) => m.id !== model.id),
                                  enabledModels: settings.enabledModels.filter((id) => id !== model.id),
                                });
                              }}
                            >
                              <span className="material-symbols-outlined text-[16px]">delete</span>
                            </button>
                          ) : null}
                          <input
                            type="checkbox"
                            className="size-4 rounded border-white/20 bg-transparent text-white focus:ring-white/20"
                            checked={settings.enabledModels.includes(model.id)}
                            onChange={(event) => {
                              const next = event.target.checked
                                ? [...settings.enabledModels, model.id]
                                : settings.enabledModels.filter((id) => id !== model.id);
                              setSettings({ ...settings, enabledModels: next });
                            }}
                          />
                        </div>
                      </label>
                    );
                  })}
                </div>
              </div>
            ) : null}

            {settingsTab === "appearance" ? (
              <div className="space-y-4">
                <div className="space-y-2">
                  <div>
                    <p className="text-sm text-[var(--text-primary)]">Themes</p>
                    <p className="text-xs text-[var(--text-secondary)]">Award-winning palettes only.</p>
                  </div>
                  <div className="grid grid-cols-1 gap-2 md:grid-cols-3">
                    {themeOptions.map((option) => {
                      const selected = settings.theme === option.id;
                      return (
                        <button
                          key={option.id}
                          className={cn(
                            "flex items-center gap-3 rounded-2xl border px-4 py-3 text-left transition-colors",
                            selected
                              ? "border-[var(--text-primary)] bg-[var(--surface-2)]"
                              : "border-[var(--border-subtle)] bg-[var(--accent-soft)] hover:bg-[var(--hover-bg)]"
                          )}
                          onClick={() => setSettings({ ...settings, theme: option.id })}
                        >
                          <span
                            className="h-10 w-10 rounded-xl border border-white/10"
                            style={{ background: option.preview }}
                          />
                          <span className="min-w-0">
                            <span className="block text-sm text-[var(--text-primary)]">{option.name}</span>
                            <span className="block text-xs text-[var(--text-secondary)]">{option.description}</span>
                          </span>
                        </button>
                      );
                    })}
                  </div>
                </div>

                <div className="flex items-center justify-between rounded-2xl border border-[var(--border-subtle)] bg-[var(--accent-soft)] px-4 py-3">
                  <div>
                    <p className="text-sm text-[var(--text-primary)]">Mode</p>
                    <p className="text-xs text-[var(--text-secondary)]">
                      {isMatrixTheme ? "Matrix is dark-only." : "Light or dark, per theme."}
                    </p>
                  </div>
                  <div className="flex items-center rounded-xl border border-[var(--border-subtle)] bg-[var(--surface-1)] p-1">
                    {(["light", "dark"] as const).map((mode) => (
                      <button
                        key={mode}
                        className={cn(
                          "px-3 py-1.5 rounded-lg text-xs font-semibold transition-colors",
                          settings.colorMode === mode
                            ? "bg-[var(--text-primary)] text-[var(--surface-1)]"
                            : "text-[var(--text-secondary)] hover:text-[var(--text-primary)]",
                          isMatrixTheme && mode === "light" ? "opacity-40 cursor-not-allowed" : ""
                        )}
                        onClick={() => {
                          if (isMatrixTheme && mode === "light") return;
                          setSettings({ ...settings, colorMode: mode });
                        }}
                      >
                        {mode === "light" ? "Light" : "Dark"}
                      </button>
                    ))}
                  </div>
                </div>
              </div>
            ) : null}

            <div className="mt-6 flex items-center justify-between">
              <p className="text-xs text-[var(--text-secondary)]">
                For maximum security, use a backend proxy in production. Client-only keys are visible to users.
              </p>
              <button
                className="px-4 py-2 rounded-xl bg-white text-black text-sm font-semibold hover:bg-slate-200"
                onClick={() => setShowSettings(false)}
              >
                Done
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
