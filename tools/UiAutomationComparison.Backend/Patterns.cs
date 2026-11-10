using System;
using System.Linq;
using FlaUI.Core;
using FlaUI.Core.Identifiers;
using FlaUI.Core.Patterns;
using NativeElement = FlaUI.Core.AutomationElements.AutomationElement;
using Legacy = System.Windows.Automation;

namespace FingVibe.UiComparison
{
    public sealed class InvokePattern
    {
        private readonly IInvokePattern pattern;
        internal InvokePattern(NativeElement element) => pattern = element.Patterns.Invoke.Pattern;
        public static Legacy.AutomationPattern Pattern => Legacy.InvokePattern.Pattern;
        public void Invoke() => AutomationElement.Call(() => pattern.Invoke());
    }

    public sealed class ValuePattern
    {
        private readonly IValuePattern pattern;
        internal ValuePattern(NativeElement element) => pattern = element.Patterns.Value.Pattern;
        public static Legacy.AutomationPattern Pattern => Legacy.ValuePattern.Pattern;
        public ValueInformation Current => new ValueInformation(pattern);
        public void SetValue(string value) => AutomationElement.Call(() => pattern.SetValue(value));
        public sealed class ValueInformation
        {
            private readonly IValuePattern pattern;
            internal ValueInformation(IValuePattern pattern) => this.pattern = pattern;
            public string Value => AutomationElement.Call(() => pattern.Value.Value);
        }
    }

    public sealed class TogglePattern
    {
        private readonly ITogglePattern pattern;
        internal TogglePattern(NativeElement element) => pattern = element.Patterns.Toggle.Pattern;
        public static Legacy.AutomationPattern Pattern => Legacy.TogglePattern.Pattern;
        public ToggleInformation Current => new ToggleInformation(pattern);
        public void Toggle() => AutomationElement.Call(() => pattern.Toggle());
        public sealed class ToggleInformation
        {
            private readonly ITogglePattern pattern;
            internal ToggleInformation(ITogglePattern pattern) => this.pattern = pattern;
            public Legacy.ToggleState ToggleState => AutomationElement.Call(() =>
                (Legacy.ToggleState)(int)pattern.ToggleState.Value);
        }
    }

    public sealed class ExpandCollapsePattern
    {
        private readonly IExpandCollapsePattern pattern;
        internal ExpandCollapsePattern(NativeElement element) => pattern = element.Patterns.ExpandCollapse.Pattern;
        public static Legacy.AutomationPattern Pattern => Legacy.ExpandCollapsePattern.Pattern;
        public ExpandCollapseInformation Current => new ExpandCollapseInformation(pattern);
        public void Expand() => AutomationElement.Call(() => pattern.Expand());
        public void Collapse() => AutomationElement.Call(() => pattern.Collapse());
        public sealed class ExpandCollapseInformation
        {
            private readonly IExpandCollapsePattern pattern;
            internal ExpandCollapseInformation(IExpandCollapsePattern pattern) => this.pattern = pattern;
            public Legacy.ExpandCollapseState ExpandCollapseState => AutomationElement.Call(() =>
                (Legacy.ExpandCollapseState)(int)pattern.ExpandCollapseState.Value);
        }
    }

    public sealed class SelectionItemPattern
    {
        private readonly ISelectionItemPattern pattern;
        internal SelectionItemPattern(NativeElement element) => pattern = element.Patterns.SelectionItem.Pattern;
        public static Legacy.AutomationPattern Pattern => Legacy.SelectionItemPattern.Pattern;
        public SelectionItemInformation Current => new SelectionItemInformation(pattern);
        public void Select() => AutomationElement.Call(() => pattern.Select());
        public void RemoveFromSelection() => AutomationElement.Call(() => pattern.RemoveFromSelection());
        public sealed class SelectionItemInformation
        {
            private readonly ISelectionItemPattern pattern;
            internal SelectionItemInformation(ISelectionItemPattern pattern) => this.pattern = pattern;
            public bool IsSelected => AutomationElement.Call(() => pattern.IsSelected.Value);
        }
    }

    public sealed class SelectionPattern
    {
        private readonly ISelectionPattern pattern;
        internal SelectionPattern(NativeElement element) => pattern = element.Patterns.Selection.Pattern;
        public static Legacy.AutomationPattern Pattern => Legacy.SelectionPattern.Pattern;
        public SelectionPatternInformation Current => new SelectionPatternInformation(pattern);
        public sealed class SelectionPatternInformation
        {
            private readonly ISelectionPattern pattern;
            internal SelectionPatternInformation(ISelectionPattern pattern) => this.pattern = pattern;
            public AutomationElement[] GetSelection() => AutomationElement.Call(() =>
                pattern.Selection.Value.Select(element => new AutomationElement(element)).ToArray());
        }
    }

    public sealed class ScrollPattern
    {
        private readonly IScrollPattern pattern;
        internal ScrollPattern(NativeElement element) => pattern = element.Patterns.Scroll.Pattern;
        public static Legacy.AutomationPattern Pattern => Legacy.ScrollPattern.Pattern;
        public ScrollInformation Current => new ScrollInformation(pattern);
        public void SetScrollPercent(double horizontal, double vertical) =>
            AutomationElement.Call(() => pattern.SetScrollPercent(horizontal, vertical));
        public void Scroll(Legacy.ScrollAmount horizontal, Legacy.ScrollAmount vertical) =>
            AutomationElement.Call(() => pattern.Scroll((FlaUI.Core.Definitions.ScrollAmount)(int)horizontal,
                (FlaUI.Core.Definitions.ScrollAmount)(int)vertical));
        public sealed class ScrollInformation
        {
            private readonly IScrollPattern pattern;
            internal ScrollInformation(IScrollPattern pattern) => this.pattern = pattern;
            public bool VerticallyScrollable => AutomationElement.Call(() => pattern.VerticallyScrollable.Value);
            public bool HorizontallyScrollable => AutomationElement.Call(() => pattern.HorizontallyScrollable.Value);
            public double VerticalScrollPercent => AutomationElement.Call(() => pattern.VerticalScrollPercent.Value);
            public double VerticalViewSize => AutomationElement.Call(() => pattern.VerticalViewSize.Value);
        }
    }

    public sealed class ScrollItemPattern
    {
        private readonly IScrollItemPattern pattern;
        internal ScrollItemPattern(NativeElement element) => pattern = element.Patterns.ScrollItem.Pattern;
        public static Legacy.AutomationPattern Pattern => Legacy.ScrollItemPattern.Pattern;
        public void ScrollIntoView() => AutomationElement.Call(() => pattern.ScrollIntoView());
    }

    public sealed class RangeValuePattern
    {
        private readonly IRangeValuePattern pattern;
        internal RangeValuePattern(NativeElement element) => pattern = element.Patterns.RangeValue.Pattern;
        public static Legacy.AutomationPattern Pattern => Legacy.RangeValuePattern.Pattern;
        public RangeInformation Current => new RangeInformation(pattern);
        public void SetValue(double value) => AutomationElement.Call(() => pattern.SetValue(value));
        public sealed class RangeInformation
        {
            private readonly IRangeValuePattern pattern;
            internal RangeInformation(IRangeValuePattern pattern) => this.pattern = pattern;
            public double Value => AutomationElement.Call(() => pattern.Value.Value);
            public double Maximum => AutomationElement.Call(() => pattern.Maximum.Value);
        }
    }

    public sealed class TextPattern
    {
        private readonly ITextPattern pattern;
        internal TextPattern(NativeElement element) => pattern = element.Patterns.Text.Pattern;
        public static Legacy.AutomationPattern Pattern => Legacy.TextPattern.Pattern;
        public static Legacy.AutomationTextAttribute FontSizeAttribute => Legacy.TextPattern.FontSizeAttribute;
        public static Legacy.AutomationTextAttribute FontNameAttribute => Legacy.TextPattern.FontNameAttribute;
        public TextRange DocumentRange => AutomationElement.Call(() => new TextRange(pattern.DocumentRange));
    }

    public sealed class TextRange
    {
        private readonly ITextRange range;
        internal TextRange(ITextRange range) => this.range = range;
        public string GetText(int maximumLength) => AutomationElement.Call(() => range.GetText(maximumLength));
        public object GetAttributeValue(Legacy.AutomationTextAttribute attribute) =>
            AutomationElement.Call(() => range.GetAttributeValue(TextAttributeId.Find(AutomationType.UIA3, attribute.Id)));
    }
}
