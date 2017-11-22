#! /usr/bin/perl

package LineTracker;

use warnings;
use strict;
use 5.010;
use Carp;

sub new {
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my $self = {};
	bless ($self, $class);
	return $self;
}

sub clear {
	my $self = shift;
	$self->{file} = undef;
	$self->{line} = undef;
}

sub advance_lines {
	my $self = shift;
	my $number_of_lines = shift;
	if(defined $self->{line}) {
		$self->{line} += $number_of_lines;
	}
}

sub directive {
	my $self = shift;
	if(defined $self->{line}) {
		my $str = "#line $self->{line}";
		if(defined $self->{file}) {
			$str .= qq( "$self->{file}");
		}
		return $str;
	}
	return undef;
}

# Returns 1 if definitely equal, 0 if definitely unequal, or undef if both operands are defined.
sub undef_based_equals {
	my($a, $b) = @_;
	if(defined $a) {
		if(defined $b) {
			return undef; # Both defined
		} else {
			return 0; # Not equal; a is defined and b is not
		}
	}
	else {
		# a is not defined
		if(defined $b) {
			return 0; # Not equals; a is not defined and b is defined
		}
		else {
			return 1; # Equal; both are undef
		}
	}
}

sub eq_string_or_undef {
	my $a = shift;
	my $b = shift;

	my $ue = undef_based_equals($a, $b);
	return defined($ue) ? $ue : $a eq $b;
}

sub eq_number_or_undef {
	my $a = shift;
	my $b = shift;

	my $ue = undef_based_equals($a, $b);
	return defined($ue) ? $ue : $a == $b;
}

sub update {
	my $self = shift;
	my $new_line = shift;
	my $new_file = shift;

	if(not defined $new_file) {
		$new_file = $self->{file};
	}
	if(not defined $new_line) {
		$new_line = $self->{line};
	}

	my $file_changed = not eq_string_or_undef($self->{file}, $new_file);
	my $line_changed = not eq_number_or_undef($self->{line}, $new_line);
	my $changed = +($file_changed || $line_changed);

	$self->{file} = $new_file;
	$self->{line} = $new_line;

	return $changed;
}

sub get {
	my $self = shift;
	my %data = ();
	$data{file} = $self->{file} if defined $self->{file};
	$data{line} = $self->{line} if defined $self->{line};
	return \%data;
}


package main;

use warnings;
use strict;
use 5.010;
use Carp;

my $ASYNC_TASK_CLASS_NAME_PREFIX = "_ZZ_SM_TASK_";
my $ASYNC_LOCALS_CLASS_NAME_PREFIX = "_ZZ_SM_TASKLOCAL_";
my $SELF_REF = "_zz_sm_selfreference_";
my $STATE_NAME = "_zz_sm_state_";
my $LOCALS_NAME = "_zz_sm_locals_";
my $SUBTASK_RUNNER_NAME = "_zz_sm_subtaskrunner_";
my $LOOP_LABEL_PREFIX = "_ZZ_SM_LABEL_";

my $in_pp = 0;
my $plain_located = 0;

my $class_name = undef;

my %sub_name_variants = ();

my @subs = ();
my @loops = ();

sub current_sub() {
	if(@subs) {
		return $subs[$#subs];
	}
	return undef;
}

sub current_loop() {
	if(@loops) {
		return $loops[$#loops];
	}
	return undef;
}

sub get_loop_with_label($) {
	my $label = shift;
	for(reverse @loops) {
		if(defined $_->{label} and $_->{label} eq $label) {
			return $_;
		}
	}
	return undef;
}

sub in_sub() {
	return defined current_sub;
}

sub in_loop() {
	return defined current_loop;
}

sub push_new_sub() {
	push @subs, {
		class => undef,
		name => undef,
		access => { value => 'private' },
		params => [],
		locals => [],
		lines => [],
	};
}

sub push_new_loop() {
	push @loops, {
		lines => [],
		label => undef,
		start_command => undef,
		end_command => undef,
		test_command => undef,
		incr_command => undef,
		post_condition => 0,
	};
}

sub get_loop_test_command_if_not_blank($$) {
	my $pp_line_stripped = shift;
	my $inversion_keyword = shift;
	return undef if $pp_line_stripped eq '';

	my $invert = 0;
	if(defined $inversion_keyword) {
		if($inversion_keyword =~ /^(?:until|unless)$/) {
			$invert = 1;
		}
	}
	return annot(value => fix_dollars($pp_line_stripped), command => 'test', invert => $invert);
}


sub add_loop_test_if_not_blank($$) {
	my $pp_line_stripped = shift;
	my $inversion_keyword = shift;

	my $test_command = get_loop_test_command_if_not_blank($pp_line_stripped, $inversion_keyword);

	return 0 unless defined $test_command;

	if(defined current_loop->{test_command}) {
		croak "Loop condition already defined at " . current_loop->{test_command}{line};
	}

	current_loop->{test_command} = $test_command;
	push @{current_loop->{lines}}, $test_command;

	return 1;
}

sub get_line_directive {
	my $line = shift // $.;
	my $file = shift // $ARGV;
	return qq(#line $line "$file");
}

sub get_hash_line_directive {
	my $rh = shift;
	my $line = $rh->{line} // $.;
	my $file = $rh->{file} // $ARGV;
	return get_line_directive($line, $file);
}

sub annot {
	my $data = { @_ };
	$data->{line} //= $.;
	$data->{file} //= $ARGV;
	return $data;
}

sub pop_sub();

sub pop_loop() {
	# Just pop the loop.
	# Code will be rendered in pop_sub.
	my $loop = pop @loops;
	if(not defined $loop) {
		croak "Attempted to close current loop while there is no current loop";
	}
	return $loop;
}

sub flatten_loop($);

sub ld {
	say get_line_directive(@_);
}

sub nonplain_ld {
	$plain_located = 0;
	say get_line_directive(@_);
}

sub plain_ld {
	if(not $plain_located) {
		say get_line_directive(@_);
		$plain_located = 1;
	}
}

sub fix_dollars {
	my $str = shift;
	for($str) {
		if(defined current_sub->{class}) {
			my $class = current_sub->{class}{name};
			s/(?:\$::)/ ${class}::/g;
			s/(?:\$\.)/($SELF_REF)./g;
		}
		s/\$(\w+)/($LOCALS_NAME).$1/g;
		return $_;
	}
}

while(<>) {
	chomp;

	my $line = $_;
	my $pp_command;
	my $pp_line;
	my $pp_line_stripped;

	if(/^\s*\[([^]]*)\]\s*(.*?)$/) {
		$pp_command = $1;
		$pp_line = $2;
		$pp_line_stripped = $pp_line;
		for($pp_line_stripped) {
			s#//.*$##g;
			s/^(?:\s*;)+\s*//g;
			s/(?:\s*;)+\s*$//g;
			s/^\s+$//g;
		}
	}

	if($in_pp) {
		if(not defined $pp_command) {
			if(in_loop) {
				my $fixed = fix_dollars($line);
				push @{current_loop->{lines}}, annot(value => $fixed, command => undef);
			}
			elsif(in_sub) {
				my $fixed = fix_dollars($line);
				push @{current_sub->{lines}}, annot(value => $fixed, command => undef);
			}
			else {
				if(not $plain_located) {
					ld();
					$plain_located = 1;
				}
				print $line . "\n";
			}
		}
		elsif($pp_command eq 'class_name') {
			if(in_sub) {
				croak "Cannot change class name inside sub";
			}
			if($pp_line_stripped eq '') {
				$class_name = undef;
			}
			else {
				$class_name = annot(value => $pp_line_stripped);
			}
		}
		elsif($pp_command eq 'access') {
			if(!in_sub) {
				croak "Access specifier cannot be defined outside a sub";
			}
			if($pp_line_stripped !~ /^(?:public|private|protected)$/) {
				croak "Access specified must be 'public', 'private', or 'protected'";
			}
			current_sub->{access} = annot(value => $pp_line_stripped);
		}
		elsif($pp_command =~ /^(?:param|var)$/) {
			if ($pp_line_stripped eq '') {
				croak "$pp_command directive must include declaration text";
			}
			if (!in_sub) {
				croak "$pp_command declaration cannot be made outside a sub";
			}
			if($pp_line_stripped =~ /^\s*(.*?)\s+(\w+)$/) {
				my $data = annot(decl => $pp_line_stripped, name => $2, type => $1);
				my $rl = +($pp_command eq 'param') ? current_sub->{params} : current_sub->{locals};
				push @$rl, $data;
			}
			else {
				croak "The $pp_command declaration '$pp_line_stripped' could not be split into a type and a name";
			}
		}
		elsif($pp_command =~ /^await|poll_(?:while|until)$/) {
			if($pp_line_stripped eq '') {
				croak "$pp_command directive must include expression text";
			}
			if(!in_sub) {
				croak "$pp_command directive cannot be made outside a sub";
			}
			push @{current_sub->{lines}}, annot(value => fix_dollars($pp_line_stripped), command => $pp_command);
		}
		elsif($pp_command eq 'end_async_pp') {
			if ($pp_line_stripped ne '') {
				croak "$pp_command directive does not allow line text";
			}
			elsif (in_sub) {
				croak "$pp_command is not valid inside a sub";
			}
			nonplain_ld();
			print "// async pp stopped here : $line\n";
			$in_pp = 0;
		}
		elsif($pp_command eq 'async_sub') {
			if ($pp_line_stripped eq '') {
				croak "$pp_command does not currently support nameless subs";
			}
			push_new_sub;
			current_sub->{class} = $class_name;
			current_sub->{name} = annot(value => $pp_line_stripped);
		}
		elsif($pp_command eq 'end_async_sub') {
			if ($pp_line_stripped ne '') {
				croak "$pp_command directive does not allow line text";
			}
			elsif (in_loop) {
				croak "$pp_command is not valid while a loop is open";
			}
			elsif (!in_sub) {
				croak "$pp_command is not valid outside a sub";
			}

			pop_sub();
		}
		elsif($pp_command =~ /^(do)(?:_(while|until))?(?::(\w+))?$/) {
			my $label = $3;
			my $while_until = $2;
			$pp_command = $1;
			if(!in_sub) {
				croak "$pp_command is not valid outside a sub";
			}
			if($pp_line_stripped eq '' and defined $while_until) {
				croak "$pp_command cannot specify while/until without a condition";
			}

			# Grab these before pushing the new loop
			my $in_outer_loop = in_loop;
			my $outer_loop = current_loop;

			push_new_loop;
			my $is_test = add_loop_test_if_not_blank $pp_line_stripped, $while_until;
			current_loop->{command} = 'place_loop';
			current_loop->{label} = $label;
			my $command = annot(value => $pp_line_stripped, command => $pp_command, while_until => $while_until);
			current_loop->{start_command} = $command;
			unshift @{current_loop->{lines}}, $command; # Since this is the starting command, put it before the test if any

			
			my $rlines = $in_outer_loop ? $outer_loop->{lines} : current_sub->{lines};
			push @$rlines, current_loop;
		}
		elsif($pp_command =~ /^(loop)(?:_(while|until))?$/) {
			my $while_until = $2;
			$pp_command = $1;
			if (!in_loop) {
				croak "$pp_command is not valid outside a loop";
			}
			if($pp_line_stripped eq '' and defined $while_until) {
				croak "$pp_command cannot specify while/until without a condition";
			}
			my $is_test = add_loop_test_if_not_blank $pp_line_stripped, $while_until;
			current_loop->{post_condition} = $is_test;
			my $command = annot(value => $pp_line_stripped, command => $pp_command, while_until => $while_until);
			current_loop->{end_command} = $command;
			push @{current_loop->{lines}}, $command;

			my $closing_loop = pop_loop();
			if(!in_loop) {
				push @{current_sub->{lines}}, flatten_loop($closing_loop);
			}
		}
		elsif($pp_command eq 'done') {
			if(!in_loop) {
				croak "$pp_command is not valid outside a loop";
			}
			if($pp_line_stripped ne '') {
				croak "$pp_command cannot specify a condition";
			}
			my $command = annot(value => $pp_line_stripped, command => $pp_command);
			current_loop->{end_command} = $command;
			push @{current_loop->{lines}}, $command;

			my $closing_loop = pop_loop();
			if(!in_loop) {
				push @{current_sub->{lines}}, flatten_loop($closing_loop);
			}
		}
		elsif($pp_command =~ /^(test)(?:_(if|unless))?$/) {
			my $if_unless = $2;
			$pp_command = $1;
			if (!in_loop) {
				croak "$pp_command is not valid outside a loop";
			}
			if ($pp_line_stripped eq '') {
				croak "$pp_command must specify a condition";
			}
			add_loop_test_if_not_blank $pp_line_stripped, $if_unless;
		}
		elsif($pp_command eq 'incr') {
			if (!in_loop) {
				croak "$pp_command is not valid outside a loop";
			}
			if ($pp_line_stripped ne '') {
				croak "$pp_command cannot specify an expression";
			}
			my $incr_command = annot(command => $pp_command);
			current_loop->{incr_command} = $incr_command;
			push @{current_loop->{lines}}, $incr_command;
		}
		elsif($pp_command =~ /^(last|next|redo)(?:_(if|unless))?(?::(\w+))?$/) {
			my $label = $3;
			my $if_unless = $2;
			$pp_command = $1;
			if (!in_loop) {
				croak "$pp_command is not valid outside a sub";
			}

			my $target_loop = current_loop;
			if (defined $label) {
				$target_loop = get_loop_with_label $label;
				if (not defined $target_loop) {
					croak "$pp_command labeled $label is not valid outside a loop with that label";
				}
			}

			my $cond = undef;
			if($pp_line_stripped ne '') {
				$cond = fix_dollars($pp_line_stripped);
			}

			my @invert;
			if(defined $if_unless) {
				if(not defined $cond) {
					croak "$pp_command cannot specify if/unless without a condition";
				}
				else {
					@invert = (invert => +($if_unless eq 'unless') ? 1 : 0);
				}
			}

			my $line = annot(value => $cond, command => $pp_command, target_loop => $target_loop, @invert);
			push @{current_loop->{lines}}, $line;
		}
		else {
			carp "Directive '$pp_command' not recognized here";
			nonplain_ld();
			my $out_line = $line;
			chomp $out_line;
			say "$out_line // async pp did not recognize directive '$pp_command'";
		}
	}
	else {
		if(defined $pp_command and $pp_command eq 'start_async_pp') {
			if ($pp_line_stripped ne '') {
				croak "$pp_command directive does not allow line text";
			}
			$in_pp = 1;
		}
		else {
			plain_ld();
			print "$line\n";
		}
	}

}


# .............

# The idea:
# Label the beginning of the loop with ...

my $unnamed_label_index = 0;

sub _flatten_loop_part {
	my $loop = shift;
	my $rl = shift;

	if(not defined $loop->{start_label}) {
		my $goto_label_base;
		if($loop->{label}) {
			$goto_label_base = "${LOOP_LABEL_PREFIX}_LABEL_$loop->{label}";
		} else {
			my $index = $unnamed_label_index++;
			$goto_label_base = "${LOOP_LABEL_PREFIX}_INDEX_$index";
		}

		$loop->{start_label} = "${goto_label_base}_START";
		$loop->{redo_label} = "${goto_label_base}_REDO";
		$loop->{last_label} = "${goto_label_base}_LAST";
		$loop->{next_label} = "${goto_label_base}_NEXT";
	}

	my $finite = defined $loop->{test_command};
	my $post_condition = $loop->{post_condition};

	$loop->{start_command}{start_target} = 1;
	(+($finite and not $post_condition) ? $loop->{test_command} : $loop->{start_command})->{redo_target} = 1;

	if($loop->{end_command}{command} ne 'done') {
		$loop->{end_command}{repeat_command_target} = 1;
	}
	# Otherwise, "done" means don't repeat (but still provide redo/last/next
	# labels)
	
	$loop->{end_command}{last_target} = 1;
	(+(defined $loop->{incr_command}) ? $loop->{incr_command} : $loop->{end_command})->{next_target} = 1;

	# If start and redo labels are in the same place, their order doesn't
	# technically matter, but as a matter of style the start should come
	# first.
	#
	# If the repeat command and the last and next labels are in the same
	# place, the next label must come first, then the repeat command, then
	# the last label.
	
	for(@{$loop->{lines}}) {
		my $command = $_->{command};

		if($_->{start_target}) {
			my %oc = %$_;
			$oc{command} = 'place_goto_label';
			$oc{goto_label} = $loop->{start_label};
			push @$rl, \%oc;
		}

		my $processed = 0;

		if(defined $command) {
			$processed = 1;

			if($command eq 'place_loop') {
				# Inline a nested loop.
				_flatten_loop_part($_, $rl);
			}
			elsif($command =~ /^(?:do|loop|done)$/) {
				# Neither of these do anything by themselves.
				# If a condition is given, it has been converted to a test
				# already.
			}
			elsif($command eq 'incr') {
				# Also does nothing by itself.
			}
			elsif($command eq 'test') {
				# value is a testable conditional expression.
				# invert is whether to invert the expression first.
				my %copy = %$_;
				$copy{command} = 'place_goto_command';
				$copy{invert} = not $_->{invert};
				# value stays the same
				$copy{goto_label} = $loop->{last_label};
				push @$rl, \%copy;
			}
			elsif($command =~ /^(?:next|last|redo)$/) {
				my %copy = %$_;
				$copy{command} = 'place_goto_command';
				my $label_key = "${command}_label";
				$copy{goto_label} = $_->{target_loop}{$label_key};
				push @$rl, \%copy;
			}
			else {
				$processed = 0;
			}
		}

		# Catch anything we didn't process
		if(not $processed) {
			push @$rl, $_;
		}

		if($_->{redo_target}) {
			my %oc = %$_;
			$oc{command} = 'place_goto_label';
			$oc{goto_label} = $loop->{redo_label};
			push @$rl, \%oc;
		}
		if($_->{next_target}) {
			my %oc = %$_;
			$oc{command} = 'place_goto_label';
			$oc{goto_label} = $loop->{next_label};
			push @$rl, \%oc;
		}
		if($_->{repeat_command_target}) {
			my %oc = %$_;
			$oc{command} = 'place_goto_command';
			$oc{goto_label} = $loop->{start_label};
			push @$rl, \%oc;
		}
		if($_->{last_target}) {
			my %oc = %$_;
			$oc{command} = 'place_goto_label';
			$oc{goto_label} = $loop->{last_label};
			push @$rl, \%oc;
		}
	}
}

sub flatten_loop($) {
	my $loop = shift;
	my @result;
	_flatten_loop_part($loop, \@result);
	return @result;
}

sub pop_sub() {
	my $sub = pop @subs;
	if(not defined $sub) {
		croak "Attempted to output current sub while there is not current sub";
	}

	my $async_sub_name = $sub->{name}{value};

	# This "variant index" allows async subs with the same name to be
	# implemented as overloads. The task class has the index in its name,
	# but the function does not.
	my $variant_index;
	for($sub_name_variants{$async_sub_name}) {
		if(not defined) {
			$_ = 0;
		} else {
			$_++;
		}
		$variant_index = $_;
	}
	my $variant_suffix = "_VT$variant_index";

	my $async_class_name = "$ASYNC_TASK_CLASS_NAME_PREFIX$async_sub_name$variant_suffix";
	my $async_locals_class_name = "$ASYNC_LOCALS_CLASS_NAME_PREFIX$async_sub_name$variant_suffix";

	my $has_self = defined $sub->{class};
	my $self_name = $has_self ? "$SELF_REF" : undef;
	my $self_decl = $has_self ? "$sub->{class}{value} & $self_name" : "";

	my $state_name = "$STATE_NAME";

	my $locals_decl;
	{
		my @locals_decls = ();
        
		my $lt0 = new LineTracker;

		$lt0->clear();
		push @locals_decls, "// [param] variables";
		for (@{$sub->{params}}) {
			my @lines = ();
			my $print_ld = $lt0->update($_->{line}, $_->{file}) ? 1 : 0;
			if($print_ld) {
				push @lines, $lt0->directive();
			}
			push @lines, qq($_->{decl};);
			push(@locals_decls, @lines);
			$lt0->advance_lines(scalar @lines - $print_ld);
		}

		$lt0->clear();
		push @locals_decls, "// [var] variables";
		for (@{$sub->{locals}}) {
			my @lines = ();
			my $print_ld = $lt0->update($_->{line}, $_->{file}) ? 1 : 0;
			if($print_ld) {
				push @lines, $lt0->directive();
			}
			push @lines, qq($_->{decl};);
			push(@locals_decls, @lines);
			$lt0->advance_lines(scalar @lines - $print_ld);
		}

		for(@locals_decls) {
			$_ = "\t\t\t\t\t$_\n";
		}

		$locals_decl = join("", @locals_decls);
	}

	my $formal_param_list;
	my $formal_param_list_with_self;
	my $informal_param_list;
	my $informal_param_list_with_self;
	my $locals_initializer;
	my $class_locals_initializer;
	{
		my @formal;
		my @informal;

		for(@{$sub->{params}}) {
			push @formal, $_->{decl};
			push @informal, $_->{name};
		}

		my @local_inits = @informal;

		for(@local_inits) {
			$_ = "$_($_)";
		}

		my @self_formal = @formal;

		if($has_self) {
			unshift(@self_formal, $self_decl);
		}

		my @self_informal = @informal;

		if($has_self) {
			unshift(@self_informal, "*this");
		}

		$formal_param_list = join(", ", @formal);
		$formal_param_list_with_self = join(", ", @self_formal);
		$informal_param_list = join(", ", @informal);
		$informal_param_list_with_self = join(", ", @self_informal);
		$locals_initializer = join(", ", @local_inits);

		$class_locals_initializer = "$LOCALS_NAME($informal_param_list)";
		if($has_self) {
			$class_locals_initializer = "$self_name($self_name), $class_locals_initializer";
		}
	}

	my $locals_initializer_clause = +($locals_initializer eq '' ? '' : ": $locals_initializer");


	my $lt = new LineTracker;
	my @switch_lines = ("case 0:");
	my $case_number = 0;

	for(@{$sub->{lines}}) {
		my $command = $_->{command};
		my $line_number = $_->{line};
		my $line_file = $_->{file};


		if(not defined $command) {
			# This is a plain line
			# If it's blank, we should ignore it; otherwise a line directive may be dumped for a blank line
			my $update_directive = $lt->update($line_number, $line_file);
			if($update_directive and $_->{value} =~ /^\s*$/) {
				# Don't output a line directive for a blank line
			}
			else {
				if($update_directive) {
					push @switch_lines, $lt->directive();
				}
				push @switch_lines, "\t" . $_->{value};
				$lt->advance_lines(1);
			}
		}
		elsif($command eq 'place_loop') {
			# Just skip this command; it's already been handled in the
			# linearization of the loop
		}
		elsif($command eq 'place_goto_command') {
			if($lt->update($line_number, $line_file)) {
				push @switch_lines, $lt->directive();
			}

			my $goto_label = $_->{goto_label};
			my $out = "goto $goto_label;";

			my $value = $_->{value};
			if(defined $value and $value ne '') {
				my $cond = $value;
				if($_->{invert}) {
					$cond = "!(" . $cond . ")";
				}
				$out = "if ($cond) $out";
			}

			push @switch_lines, "\t$out";
			$lt->advance_lines(1);
		}
		elsif($command eq 'place_goto_label') {
			if($lt->update($line_number, $line_file)) {
				push @switch_lines, $lt->directive();
			}

			my $goto_label = $_->{goto_label};
			push @switch_lines, "$goto_label:";
			$lt->advance_lines(1);
		}
		elsif($command =~ /^(?:await|poll_(?:while|until))$/) {
			$lt->advance_lines(1);
			push @switch_lines, "";

			if($lt->update($line_number, $line_file)) {
				push @switch_lines, $lt->directive();
			}

			++$case_number;
			my $before_lines = scalar @switch_lines;
			if($command eq 'await') {
				push @switch_lines,
					"\t$SUBTASK_RUNNER_NAME.begin($_->{value});",
					"\t$STATE_NAME = $case_number;",
					"case $case_number:",
					"\tif (!$SUBTASK_RUNNER_NAME.finish()) return false;",
					"";
			}
			elsif($command =~ /^poll_(while|until)$/) {
				my $cond = $_->{value};
				if($1 eq 'until') {
					$cond = "!($cond)";
				}

				push @switch_lines,
					"\t$STATE_NAME = $case_number;",
					"case $case_number:",
					"\tif ($cond) return false;",
					"";
			}
			my $after_lines = scalar @switch_lines;
			$lt->advance_lines($after_lines - $before_lines);
		}
		else {
			croak "An in-sub command had the name '$command', which was not recognized";
		}
	}

	push @switch_lines, "default:", "\treturn true;";

	for(@switch_lines) {
		$_ = "\t\t\t\t\t$_";
	}

	my $switch_body = join("\n", @switch_lines);


	print <<EOF;

	private:

	class $async_class_name : public HgkAsync::StateAsyncTask
	{
		private:
			$self_decl;
			class $async_locals_class_name
			{
				public:
$locals_decl

					$async_locals_class_name(
						$formal_param_list)
						$locals_initializer_clause
					{
					}
			};

			$async_locals_class_name $LOCALS_NAME;

		public:
			$async_class_name(
				$formal_param_list_with_self)
				: $class_locals_initializer
			{
			}

		protected:
			HgkAsync::AsyncTaskRunner $SUBTASK_RUNNER_NAME;

			bool work(int & $state_name)
			{
				switch ($state_name) {
					// State machine code goes here
$switch_body
				}
			}
	};

	$sub->{access}{value}:

	HgkAsync::StateAsyncTask * $async_sub_name($formal_param_list)
	{
		return new $async_class_name($informal_param_list_with_self);
	}

	private:
EOF
}

