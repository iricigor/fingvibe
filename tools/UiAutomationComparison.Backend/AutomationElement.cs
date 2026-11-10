using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using FlaUI.Core;
using FlaUI.Core.Conditions;
using FlaUI.Core.Identifiers;
using FlaUI.UIA3;
using NativeElement = FlaUI.Core.AutomationElements.AutomationElement;
using Legacy = System.Windows.Automation;

namespace FingVibe.UiComparison
{
    // Only the automation backend changes; the experimental copies retain the original assertions.
    public sealed class AutomationElement
    {
        private static UIA3Automation? automation;
        internal static UIA3Automation Automation => automation ?? (automation = new UIA3Automation());
        internal NativeElement Native { get; }
        internal AutomationElement(NativeElement native) => Native = native;
        public static long FindCalls { get; private set; }
        public static long PatternCalls { get; private set; }
        public static long FocusCalls { get; private set; }

        public static Legacy.AutomationProperty AutomationIdProperty => Legacy.AutomationElement.AutomationIdProperty;
        public static Legacy.AutomationProperty NameProperty => Legacy.AutomationElement.NameProperty;
        public static Legacy.AutomationProperty ControlTypeProperty => Legacy.AutomationElement.ControlTypeProperty;
        public static Legacy.AutomationProperty ProcessIdProperty => Legacy.AutomationElement.ProcessIdProperty;
        public static AutomationElement RootElement => Call(() => new AutomationElement(Automation.GetDesktop()));
        public static AutomationElement? FocusedElement => Call(() => Wrap(Automation.FocusedElement()));
        public static AutomationElement FromHandle(IntPtr handle) =>
            Call(() => new AutomationElement(Automation.FromHandle(handle)));
        public static void Shutdown()
        {
            automation?.Dispose();
            automation = null;
        }

        internal static AutomationElement? Wrap(NativeElement? element) =>
            element is null ? null : new AutomationElement(element);

        internal static T Call<T>(Func<T> action)
        {
            try { return action(); }
            catch (COMException exception) when (exception.HResult == unchecked((int)0x80040201))
            {
                throw new Legacy.ElementNotAvailableException(exception.Message, exception);
            }
        }

        internal static void Call(Action action) => Call(() => { action(); return true; });
        public ElementInformation Current => new ElementInformation(Native);
        public void SetFocus()
        {
            FocusCalls++;
            Call(() => Native.Focus());
        }
        public AutomationElement? FindFirst(Legacy.TreeScope scope, Legacy.Condition condition)
        {
            FindCalls++;
            return Call(() => Wrap(Native.FindFirst((FlaUI.Core.Definitions.TreeScope)(int)scope, Convert(condition))));
        }
        public AutomationElement[] FindAll(Legacy.TreeScope scope, Legacy.Condition condition)
        {
            FindCalls++;
            return Call(() => Native.FindAll((FlaUI.Core.Definitions.TreeScope)(int)scope, Convert(condition))
                .Select(element => new AutomationElement(element)).ToArray());
        }

        internal static ConditionBase Convert(Legacy.Condition condition)
        {
            if (ReferenceEquals(condition, Legacy.Condition.TrueCondition)) return TrueCondition.Default;
            if (ReferenceEquals(condition, Legacy.Condition.FalseCondition)) return FalseCondition.Default;
            if (condition is Legacy.AndCondition and)
                return new AndCondition(and.GetConditions().Select(Convert).ToArray());
            if (condition is Legacy.OrCondition or)
                return new OrCondition(or.GetConditions().Select(Convert).ToArray());
            if (condition is Legacy.PropertyCondition property)
            {
                var value = property.Value is Legacy.ControlType control
                    ? (object)FlaUI.UIA3.Converters.ControlTypeConverter.ToControlType(control.Id) : property.Value;
                return new PropertyCondition(PropertyId.Find(AutomationType.UIA3, property.Property.Id), value,
                    (FlaUI.Core.Definitions.PropertyConditionFlags)(int)property.Flags);
            }
            throw new NotSupportedException($"Unmapped UIA condition: {condition.GetType().FullName}.");
        }

        public bool TryGetCurrentPattern(Legacy.AutomationPattern pattern, out object? result)
        {
            var supported = Call(() =>
            {
                if (pattern.Id == InvokePattern.Pattern.Id) return Native.Patterns.Invoke.IsSupported;
                if (pattern.Id == ValuePattern.Pattern.Id) return Native.Patterns.Value.IsSupported;
                if (pattern.Id == TogglePattern.Pattern.Id) return Native.Patterns.Toggle.IsSupported;
                if (pattern.Id == ExpandCollapsePattern.Pattern.Id) return Native.Patterns.ExpandCollapse.IsSupported;
                if (pattern.Id == SelectionItemPattern.Pattern.Id) return Native.Patterns.SelectionItem.IsSupported;
                if (pattern.Id == SelectionPattern.Pattern.Id) return Native.Patterns.Selection.IsSupported;
                if (pattern.Id == ScrollPattern.Pattern.Id) return Native.Patterns.Scroll.IsSupported;
                if (pattern.Id == ScrollItemPattern.Pattern.Id) return Native.Patterns.ScrollItem.IsSupported;
                if (pattern.Id == RangeValuePattern.Pattern.Id) return Native.Patterns.RangeValue.IsSupported;
                if (pattern.Id == TextPattern.Pattern.Id) return Native.Patterns.Text.IsSupported;
                throw new NotSupportedException($"Unmapped UIA pattern: {pattern.ProgrammaticName}.");
            });
            result = supported ? GetCurrentPattern(pattern) : null;
            return supported;
        }

        public object GetCurrentPattern(Legacy.AutomationPattern pattern)
        {
            PatternCalls++;
            return Call<object>(() =>
            {
                if (pattern.Id == InvokePattern.Pattern.Id) return new InvokePattern(Native);
                if (pattern.Id == ValuePattern.Pattern.Id) return new ValuePattern(Native);
                if (pattern.Id == TogglePattern.Pattern.Id) return new TogglePattern(Native);
                if (pattern.Id == ExpandCollapsePattern.Pattern.Id) return new ExpandCollapsePattern(Native);
                if (pattern.Id == SelectionItemPattern.Pattern.Id) return new SelectionItemPattern(Native);
                if (pattern.Id == SelectionPattern.Pattern.Id) return new SelectionPattern(Native);
                if (pattern.Id == ScrollPattern.Pattern.Id) return new ScrollPattern(Native);
                if (pattern.Id == ScrollItemPattern.Pattern.Id) return new ScrollItemPattern(Native);
                if (pattern.Id == RangeValuePattern.Pattern.Id) return new RangeValuePattern(Native);
                if (pattern.Id == TextPattern.Pattern.Id) return new TextPattern(Native);
                throw new NotSupportedException($"Unmapped UIA pattern: {pattern.ProgrammaticName}.");
            });
        }

        public override bool Equals(object? other) =>
            other is AutomationElement element && Call(() => Automation.Compare(Native, element.Native));
        public override int GetHashCode() => Native.GetHashCode();
    }

    public sealed class ElementInformation
    {
        private readonly NativeElement element;
        internal ElementInformation(NativeElement element) => this.element = element;
        public string AutomationId => AutomationElement.Call(() => element.AutomationId);
        public string Name => AutomationElement.Call(() => element.Name);
        public string HelpText => AutomationElement.Call(() => element.HelpText);
        public string ItemStatus => AutomationElement.Call(() => element.Properties.ItemStatus.Value);
        public int ProcessId => AutomationElement.Call(() => element.Properties.ProcessId.Value);
        public bool IsEnabled => AutomationElement.Call(() => element.IsEnabled);
        public bool IsOffscreen => AutomationElement.Call(() => element.IsOffscreen);
        public bool IsKeyboardFocusable => AutomationElement.Call(() => element.Properties.IsKeyboardFocusable.Value);
        public bool HasKeyboardFocus => AutomationElement.Call(() => element.Properties.HasKeyboardFocus.Value);
        public Legacy.ControlType ControlType =>
            AutomationElement.Call(() => Legacy.ControlType.LookupById(
                (int)FlaUI.UIA3.Converters.ControlTypeConverter.ToControlTypeNative(element.ControlType)));
        public Rect BoundingRectangle => AutomationElement.Call(() =>
        {
            var bounds = element.BoundingRectangle;
            return new Rect(bounds.Left, bounds.Top, bounds.Width, bounds.Height);
        });
    }

    public sealed class TreeWalker
    {
        public static TreeWalker ControlViewWalker { get; } = new TreeWalker();
        public AutomationElement? GetParent(AutomationElement element) =>
            AutomationElement.Call(() => AutomationElement.Wrap(
                AutomationElement.Automation.TreeWalkerFactory.GetControlViewWalker().GetParent(element.Native)));
    }
}
