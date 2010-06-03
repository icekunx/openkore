#########################################################################
#  OpenKore - WxWidgets Interface
#  You need:
#  * WxPerl (the Perl bindings for WxWidgets) - http://wxperl.sourceforge.net/
#
#  More information about WxWidgets here: http://www.wxwidgets.org/
#
#  Copyright (c) 2004,2005,2006,2007 OpenKore development team
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  $Revision$
#  $Id$
#
#########################################################################
package Interface::Wx::MainFrame;
use strict;

use Wx ':everything';
use base 'Wx::Frame';
use Wx::AUI;
use Wx::Event ':everything';
use Time::HiRes qw(time sleep);
use File::Spec;
use FindBin qw($RealBin);

use Globals;
use Interface;
use base qw(Wx::App Interface);
use Modules;
use Field;
use I18N qw/bytesToString/;

use Interface::Wx::Utils;

use Interface::Wx::MainMenu;
use Interface::Wx::Window::Input;
use Interface::Wx::Window::Console;
use Interface::Wx::Window::ChatLog;
use Interface::Wx::Window::Exp;

use AI;
use Settings qw(%sys);
use Plugins;
use Misc;
use Commands;
use Utils;
use Translation qw/T TF/;

our ($iterationTime, $updateUITime, $updateUITime2);

sub new {
	my ($class, $parent, $id, $title, @args) = @_;
	
	my $self = $class->SUPER::new($parent, $id || wxID_ANY, $title || $Settings::NAME);
	
	$self->{menu} = new Interface::Wx::MainMenu($self);
	$self->createStatusBar;
	
	$self->SetClientSize(950, 680);
	if (-f (my $icon = "$RealBin/src/build/openkore.ico")) {
		$self->SetIcon(new Wx::Icon($icon, wxBITMAP_TYPE_ICO));
	}
	
	EVT_CLOSE($self, sub {
		my ($self, $event) = @_;
		stopMainLoop;
		$self->Show(0) if $event->CanVeto;
	});
	
	$self->{hooks} = Plugins::addHooks(
		['loadfiles',     \&onLoadFiles, $self],
		['postloadfiles', \&onLoadFiles, $self],
		['mainLoop_pre',  \&onUpdate, $self],
		['interface/helpcontext', \&onHelpContext, $self],
	);
	
	$self->{windows} = {};
	
	($self->{aui} = new Wx::AuiManager)->SetManagedWindow($self);
	
	$self->{aui}->AddPane(
		$self->{notebook} = new Wx::AuiNotebook($self, wxID_ANY, wxDefaultPosition, wxDefaultSize,
			# no close buttons for tabs
			wxAUI_NB_TOP | wxAUI_NB_TAB_SPLIT | wxAUI_NB_TAB_MOVE | wxAUI_NB_SCROLL_BUTTONS
		),
		Wx::AuiPaneInfo->new->CenterPane
	);
	
=pod TODO
	wxEVT_AUINOTEBOOK_PAGE_CHANGED($self, $self->{notebook}->GetId, sub {
		Plugins::callHook('interface/defaultFocus')
	});
=cut
	
	my $input = new Interface::Wx::Window::Input($self);
	$self->{aui}->AddPane($input,
		Wx::AuiPaneInfo->new->ToolbarPane->Bottom->BestSize($input->GetBestSize)->CloseButton(0)->Resizable->LeftDockable(0)->RightDockable(0)
	);
	
	$self->toggleWindow('console', 'Interface::Wx::Window::Console', 'notebook');
	$self->toggleWindow('chatLog', 'Interface::Wx::Window::ChatLog', 'notebook');
	$self->toggleWindow('map', 'Interface::Wx::Window::Map', 'right', undef, [250, 250]);
	$self->toggleWindow('environment', 'Interface::Wx::Window::Environment', 'right', 1, [150, -1], 1);
	
	$self->{aui}->Update;
	
	$self->{notebook}->Split(1, wxBOTTOM);
	$self->{notebook}->SetSelection(0);
	
	return $self;
}

sub DESTROY {
	my ($self) = @_;
	
	$self->{aui}->UnInit;
	
	Plugins::delHooks($self->{hooks});
}

sub onLoadFiles {
	my ($hook, $args, $self) = @_;
	if ($hook eq 'loadfiles') {
		$self->{loadingFiles}{percent} = $args->{current} / (1 + scalar @{$args->{files}});
		$self->{loadingFiles}{file} = $args->{files}[$args->{current} - 1]
	} else {
		delete $self->{loadingFiles};
	}
	
	$self->updateStatusBar;
}

sub onUpdate {
	my (undef, undef, $self) = @_;
	
	if (timeOut($updateUITime, 0.15)) {
		$self->updateStatusBar;
		$updateUITime = time;
	}
	if (timeOut($updateUITime2, 0.35)) {
		#$self->updateItemList;
		$updateUITime2 = time;
	}
}

sub onHelpContext {
	my (undef, $args, $self) = @_;
	
	$self->{statusBar}->SetStatusText($args->{message}, 0);
}

sub createStatusBar {
	my ($self) = @_;
	
	$self->{statusBar} = $self->CreateStatusBar(3, wxST_SIZEGRIP | wxFULL_REPAINT_ON_RESIZE, wxID_ANY);
	$self->{statusBar}->SetStatusWidths(-1, 65, 350);
}

sub updateStatusBar {
	my $self = shift;

	my ($statText, $xyText, $aiText) = ('', '', '');

	if ($self->{loadingFiles}) {
		$statText = sprintf(T("Loading files... %.0f%% (%s)"), $self->{loadingFiles}{percent} * 100, $self->{loadingFiles}{file}{name});
	} elsif (!$conState) {
		$statText = T("Initializing...");
	} elsif ($conState == Network::NOT_CONNECTED) {
		$statText = T("Not connected");
	} elsif ($conState > Network::NOT_CONNECTED && $conState < Network::IN_GAME) {
		$statText = T("Connecting...");
	} elsif ($self->{mouseMapText}) {
		$statText = $self->{mouseMapText};
	}

	if ($conState == Network::IN_GAME) {
		$xyText = "$char->{pos_to}{x}, $char->{pos_to}{y}";

		if ($AI) {
			if (@ai_seq) {
=pod
				my @seqs = @ai_seq;
				foreach (@seqs) {
					s/^route_//;
					s/_/ /g;
					s/([a-z])([A-Z])/$1 $2/g;
					$_ = lc $_;
				}
				substr($seqs[0], 0, 1) = uc substr($seqs[0], 0, 1);
				$aiText = join(', ', @seqs);
=cut
				my @seqs = ();
				for (@ai_seq) {
					push @seqs, do {
						my $args = AI::args(scalar @seqs);
						
						return sprintf('%s (%s)', $_, $Macro::Data::queue->name) if /^macro$/ and (
							$Macro::Data::queue && ref $Macro::Data::queue && $Macro::Data::queue->can('name')
						);
						
						$_;
					}
				}
			} else {
				$aiText = "";
			}
		} else {
			$aiText = T("Paused");
		}
	}

	# Only set status bar text if it has changed
	my $i = 0;
	my $setStatus = sub {
		if (defined $_[1] && $self->{$_[0]} ne $_[1]) {
			$self->{$_[0]} = $_[1];
			$self->{statusBar}->SetStatusText($_[1], $i);
		}
		$i++;
	};

	$setStatus->('statText', $statText);
	$setStatus->('xyText', $xyText);
	$setStatus->('aiText', $aiText);
}

sub toggleWindow {
	my ($self, $key, $class, $target, $layer, $bestSize, $noCloseButton) = @_;
	
	unless ($self->{windows}{$key}) {
		eval "require $class";
		if ($@) {
			Log::warning TF("Unable to load %s\n%s", $class, $@), 'interface';
			return;
		}
		unless ($class->can('new')) {
			Log::warning TF("Unable to create instance of %s\n", $class), 'interface';
			return;
		}
		
		my $window = $class->new($self);
		
		if (my $pos = {
			'float' => wxAUI_DOCK_NONE,
			'top' => wxAUI_DOCK_TOP,
			'right' => wxAUI_DOCK_RIGHT,
			'bottom' => wxAUI_DOCK_BOTTOM,
			'left' => wxAUI_DOCK_LEFT,
		}->{$target}) {
			$self->{aui}->AddPane($window,
				Wx::AuiPaneInfo->new->Caption($window->{title})
				->Direction($pos)->Layer($layer || 0)
				->BestSize($bestSize ? @$bestSize : $window->GetBestSize)
				->DestroyOnClose->CloseButton(!$noCloseButton)->CaptionVisible(!$noCloseButton)
				->Gripper($noCloseButton)->GripperTop($pos == wxAUI_DOCK_LEFT || $pos == wxAUI_DOCK_RIGHT)
			);
			$self->{aui}->Update;
		} elsif ($target eq 'notebook') {
			$self->{notebook}->AddPage($window, $window->{title}, 1);
		}
		
		Scalar::Util::weaken($self->{windows}{$key} = $window);
	} else {
		if ($self->{aui}->GetPane($self->{windows}{$key})->IsOk) {
			$self->{aui}->DetachPane($self->{windows}{$key});
			$self->{windows}{$key}->Destroy;
			$self->{aui}->Update;
		} else {
			ref $self->{notebook}->GetPage($_) eq ref $self->{windows}{$key} && $self->{notebook}->DeletePage($_)
			for (0 .. $self->{notebook}->GetPageCount-1);
		}
	}
	
	Plugins::callHook('interface/defaultFocus');
}

=pod
##################
## Callbacks
##################

sub onBooleanSetting {
	my ($self, $setting) = @_;
	
	configModify ($setting, !$config{$setting}, 1);
}
=cut
1;
