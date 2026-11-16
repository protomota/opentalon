import {
  Activity,
  Bird,
  BookOpen,
  Bot,
  Briefcase,
  Brush,
  Building2,
  Calendar,
  Camera,
  Car,
  ChartColumn,
  ChartLine,
  Cloud,
  Code,
  Coffee,
  Compass,
  Cpu,
  Database,
  DollarSign,
  Dumbbell,
  Feather,
  Flag,
  FlaskConical,
  Gamepad2,
  Gift,
  Globe,
  GraduationCap,
  Hammer,
  Heart,
  House,
  Image,
  Inbox,
  LayoutDashboard,
  Leaf,
  Lightbulb,
  Lock,
  Mail,
  Map,
  Megaphone,
  Mic,
  Moon,
  Music,
  Newspaper,
  NotebookPen,
  Package,
  Palette,
  PenTool,
  Plane,
  Plug,
  Rocket,
  Server,
  Shield,
  ShoppingCart,
  Smartphone,
  Sparkles,
  Star,
  Sun,
  Target,
  Terminal,
  Trophy,
  User,
  Users,
  Utensils,
  Video,
  Wallet,
  Workflow,
  Wrench,
  Zap,
  type LucideIcon,
} from 'lucide-react'
import { boardIconNames, type BoardIconName } from './board-icon-names'

const components: Record<BoardIconName, LucideIcon> = {
  activity: Activity,
  bird: Bird,
  'book-open': BookOpen,
  bot: Bot,
  briefcase: Briefcase,
  brush: Brush,
  building: Building2,
  calendar: Calendar,
  camera: Camera,
  car: Car,
  'chart-column': ChartColumn,
  'chart-line': ChartLine,
  cloud: Cloud,
  code: Code,
  coffee: Coffee,
  compass: Compass,
  cpu: Cpu,
  database: Database,
  'dollar-sign': DollarSign,
  dumbbell: Dumbbell,
  feather: Feather,
  flag: Flag,
  flask: FlaskConical,
  gamepad: Gamepad2,
  gift: Gift,
  globe: Globe,
  'graduation-cap': GraduationCap,
  hammer: Hammer,
  heart: Heart,
  house: House,
  image: Image,
  inbox: Inbox,
  leaf: Leaf,
  lightbulb: Lightbulb,
  lock: Lock,
  mail: Mail,
  map: Map,
  megaphone: Megaphone,
  mic: Mic,
  moon: Moon,
  music: Music,
  newspaper: Newspaper,
  'notebook-pen': NotebookPen,
  package: Package,
  palette: Palette,
  'pen-tool': PenTool,
  plane: Plane,
  plug: Plug,
  rocket: Rocket,
  server: Server,
  shield: Shield,
  'shopping-cart': ShoppingCart,
  smartphone: Smartphone,
  sparkles: Sparkles,
  star: Star,
  sun: Sun,
  target: Target,
  terminal: Terminal,
  trophy: Trophy,
  user: User,
  users: Users,
  utensils: Utensils,
  video: Video,
  wallet: Wallet,
  workflow: Workflow,
  wrench: Wrench,
  zap: Zap,
}

export function BoardIcon({ icon, size = 17 }: { icon: string | null; size?: number }) {
  const Icon = (icon && components[icon as BoardIconName]) || LayoutDashboard
  return <Icon size={size} strokeWidth={1.65} aria-hidden="true" />
}

export function BoardIconPicker({
  value,
  disabled,
  onChange,
}: {
  value: string | null
  disabled?: boolean
  onChange: (icon: BoardIconName | null) => void
}) {
  return (
    <div className="board-icon-grid" role="group" aria-label="Project icon">
      <button
        aria-pressed={value === null}
        aria-label="Default project icon"
        title="Default"
        disabled={disabled}
        onClick={() => onChange(null)}
      >
        <BoardIcon icon={null} size={18} />
      </button>
      {boardIconNames.map((name) => (
        <button
          key={name}
          aria-pressed={value === name}
          aria-label={`${name.replace(/-/g, ' ')} icon`}
          title={name.replace(/-/g, ' ')}
          disabled={disabled}
          onClick={() => onChange(name)}
        >
          <BoardIcon icon={name} size={18} />
        </button>
      ))}
    </div>
  )
}
