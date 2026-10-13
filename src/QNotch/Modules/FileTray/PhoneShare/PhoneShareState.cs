using System.Collections.ObjectModel;
using System.Windows.Media;
using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Modules.FileTray;

/// <summary>A tray item offered for a sharing session. Folders and missing files are listed but cannot be picked (the view reads
/// <see cref="Item"/> live, since the tray may still be inspecting it).</summary>
public sealed partial class ShareChoice(TrayItem item) : ObservableObject
{
    public TrayItem Item { get; } = item;
    public bool CanShare => !Item.IsFolder && !Item.IsMissing;
    [ObservableProperty] bool _isChecked = !item.IsFolder && !item.IsMissing;
}

/// <summary>One download to or upload from the phone. Written on the UI thread.</summary>
public sealed partial class PhoneTransfer : ObservableObject
{
    public PhoneTransfer(string name, bool isUpload, long total)
    {
        Name = name;
        IsUpload = isUpload;
        Total = total;
        _detail = isUpload ? "Receiving" : "Sending";
    }

    public string Name { get; }
    /// <summary>True: phone to PC. False: PC to phone.</summary>
    public bool IsUpload { get; }
    public long Total { get; }
    public string Glyph => IsUpload ? "" : "";

    [ObservableProperty] int _percent;
    /// <summary>"Receiving", "45%", "Saved to Downloads\QNotch", "Cancelled".</summary>
    [ObservableProperty] string _detail;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(IsRunning))] bool _isDone;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(IsRunning))] bool _isFailed;
    /// <summary>Set when a received file was saved: the view can open its folder.</summary>
    [ObservableProperty] string? _savedPath;

    public bool IsRunning => !IsDone && !IsFailed;
}

/// <summary>Phone sharing: the choice of files, the running session (URL, QR, time left) and its transfers. UI thread only.</summary>
public sealed partial class PhoneShareState : ObservableObject
{
    /// <summary>Tray files to pick from before a session starts, the frozen set while it runs.</summary>
    public ObservableCollection<ShareChoice> Choices { get; } = new();
    /// <summary>Newest first.</summary>
    public ObservableCollection<PhoneTransfer> Transfers { get; } = new();
    /// <summary>Candidate LAN addresses, best first.</summary>
    public ObservableCollection<ShareAddress> Addresses { get; } = new();

    /// <summary>The Files tab shows the sharing view instead of the tray.</summary>
    [ObservableProperty] bool _isOpen;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(IsIdle))] bool _isActive;
    [ObservableProperty] string _url = "";
    [ObservableProperty] ImageSource? _qr;
    [ObservableProperty] string _timeLeft = "";
    /// <summary>"Waiting for your phone", "Phone connected", or why sharing cannot start.</summary>
    [ObservableProperty] string _status = "";
    [ObservableProperty] bool _isError;
    [ObservableProperty] string _selectionText = "";
    [ObservableProperty] ShareAddress? _address;
    [ObservableProperty] bool _hasManyAddresses;
    /// <summary>Addresses are known and at least one exists.</summary>
    [ObservableProperty] bool _canStart;
    [ObservableProperty] bool _hasTransfers;
    [ObservableProperty] bool _hasChoices;
    [ObservableProperty] bool _canExtend;

    public bool IsIdle => !IsActive;
}
