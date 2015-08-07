#!/usr/bin/env perl

use warnings;
use strict;

# Потрібно для налагодження
use utf8;
binmode STDOUT, ":utf8";
use Data::Dumper;

use 5.010;

my $command = shift @ARGV;

use JSON -convert_blessed_universally;
use Getopt::Long;
use Pod::Usage;
use WWW::Curl::Easy;
use URI::Escape;
use Hash::Merge::Simple qw/merge/;
use Data::Match qw/:all/;
use Data::Clone;
use Scalar::Util qw/refaddr/;

=encoding utf8

=head1 NAME

authors.pl — команда завантажує або оновлює інформацію про авторів з wikipedia.org

=head1 SYNOPSIS

authors.pl [COMMAND] OPTIONS

  where COMMAND := { load | update }
        OPTIONS := { --from FILE {input-file} | --to {output-file} |
                     --lang {lang} | --langs {list of langs} | --category {string} |
                     --find {json-text} | --add {json-text} |
                     --help }

=head2 SAMPLES

    ./authors.pl load \
        --from old.json --to new.json \
        --lang uk --langs=ru,en,crh \
        --category 'Категорія:Українські поети'

    ./authors.pl update \
        --from old.json --to new.json \
        --find '{"uk":"Руданський Степан Васильович"}' \
        --add '{"tags":[{"uk":"Українські класики"}]}'

=head1 DESCRIPTION

Ця команда для завантаження або оновлення інформації про авторів. Зберігає
у форматі C<api-authors.json> наступні поля:

    [
       {
          "name" : {
             "uk" : "Руданський Степан Васильович",
             "ru" : "Руданский, Степан Васильевич"
          },
          "wiki" : {
             "uk" : "https://uk.wikipedia.org/wiki/Руданський Степан Васильович",
             "ru" : "https://ru.wikipedia.org/wiki/Руданский, Степан Васильевич"
          },
          "tags" : [
             {
                "uk" : "Українські поети",
                "en" : "Ukrainian poets",
                "ru" : "Поэты Украины"
             }
          ]
       }
    ]

=head2 Options

=over 4

=item --from

Файл у форматі JSON, з якого беруться дані для доповнення.

=item --to

Файл у форматі JSON, в який будуть збережені результати.
Якщо опція не вказана, то результат виводиться у STDOUT.

=item --lang

Мова для запиту до https://www.mediawiki.org/wiki/API:Main_page
Вона же використовується для локалізації даних.
Обов'язкова опція.

=item --langs

Мови за якими завантажуються дані у інших локалізаціях.

=item --category

Вказується повна назва категорії з wikipedia.org для завантаження списку авторів.
Обов'язкова опція.

=item --find JSON

=item --add JSON

=item --change JSON

TODO

=item --delete JSON

TODO

=item --remove

TODO

=back

=cut

my $url_template_categoryinfo = 'https://{lang}.wikipedia.org/w/api.php?action=query&prop=categoryinfo&format=json&titles={titles}';
my $url_template_categorymembers = 'https://{lang}.wikipedia.org/w/api.php?action=query&format=json&list=categorymembers&cmpageid={cmpageid}&cmtype=page&cmlimit=25';
my $url_template_langlinks = 'https://{lang}.wikipedia.org/w/api.php?action=parse&format=json&pageid={pageid}&prop=langlinks';
my $url_template_info_url = 'https://{lang}.wikipedia.org/w/api.php?action=query&prop=info&format=json&inprop=url&pageids={pageids}';

my $curl;

my @langs;
my $to_file = '&STDOUT';
my $lang;
my $category_title;

my $authors = [];
my $authors_index;

my @targets;
my @actions;

GetOptions(
    'from=s'        => \&load_json,
    'to=s'          => \$to_file,
    'lang=s'        => \$lang,
    'category=s'    => \$category_title,
    'langs=s'       => \@langs,
    'find=s@'       => \&set_target,
    'add=s'         => \&set_action,
    'help|?'        => sub { pod2usage(0) }
);

# Нормалізуємо список мов
@langs = split(/,/, join(',', @langs));
unshift(@langs, $lang)
    unless $lang ~~ @langs;

if (defined $command && $command eq 'load') {

    pod2usage(-message => "Options --lang LANG and --category TITLE are required.",
              -exitval => 2,
              -verbose => 0,
              -output  => \*STDERR)
        unless defined $lang || defined $category_title;

    init_curl();

    update_authors($authors, {
        lang => $lang,
        titles => $category_title});

    save_json($to_file, $authors);

} elsif (defined $command && $command eq 'update') {

    pod2usage(-message => "Option --from FILE are required.",
              -exitval => 2,
              -verbose => 0,
              -output  => \*STDERR)
        unless exists $authors->[0];

    pod2usage(-message => "You must specify one of the options --add JSON, --change JSON, --delete JSON or --remove.",
              -exitval => 2,
              -verbose => 0,
              -output  => \*STDERR)
        unless @actions;

    pod2usage(-message => "Use --find '{}' to perform an action on all elements.",
              -exitval => 2,
              -verbose => 0,
              -output  => \*STDERR)
        unless @targets;

    pod2usage(-message => "In the incoming file data is missing.",
              -exitval => 2,
              -verbose => 0,
              -output  => \*STDERR)
        unless scalar(@{$authors});

    my $target_idx = find_targets(\@targets);

    for (@{$target_idx}) {
        my $member = $authors->[$_];
        print "$_";
        foreach my $lang (keys %{$member->{name}}) {
            print " [$lang]".$member->{name}->{$lang};
        }
        print "\n";
    }

} else {
    pod2usage(-message => "The first argument must be a COMMAND.",
              -exitval => 2,
              -verbose => 0,
              -output  => \*STDERR);
}

exit;

=head1 FUNCTIONS

=head2 load_json($file)

=cut

sub load_json {
    shift;
    my ($file) = @_;

    open(DATA, $file) || die "Can't open JSON file '$file': $!";
    $authors = JSON->new->utf8->decode(join '', <DATA>);
    close(DATA);

    # Будуємо індекс
    my $i = 0;
    foreach my $member (@{$authors}) {
        foreach my $lang (keys %{$member->{name}}) {
            $authors_index->{$lang}->{$member->{name}->{$lang}} = $i;
        }
        ++$i;
    }
}

=head2 save_json($file, $data)

=cut

sub save_json {
    my ($file, $data) = @_;

    open(DATA, ">".$file) || die $!;
    print DATA JSON->new->allow_blessed->convert_blessed->utf8->pretty->encode($data);
    close(DATA);
}

=head2 set_target($json_text)

=cut

sub set_target {
    push(@targets, JSON->new->utf8->decode($_[1]));
}

=head2 set_action($json_text)

=cut

sub set_action {
    push(@actions, {$_[0], JSON->new->utf8->decode($_[1])});
}

=head2 find_targets(\@targets)

Шукає в $authors м'які збіги, задані опціями --find {текст з JSON},
та повертає масив з індексами входжень в $authors.

=cut

sub find_targets {
    my ($targets) = @_;
    my @result;

    foreach my $target (@{$targets}) {

        pod2usage(-message => "Options --find '".JSON->new->utf8->encode($target)."' must be string of HASH.",
                  -exitval => 2,
                  -verbose => 0,
                  -output  => \*STDERR)
            unless ref($target) eq 'HASH';

        my @keys = keys %{$target};

        if ($#keys == -1) {
            # Передали порожній хеш: --find '{}'

            @result = ();
            foreach (0..scalar(@{$authors})-1) {
                push(@result, $_);
            }
            last;
        }

        my $pattern = inject_REST($target);

        my $idx = 0;
        foreach my $author (@{$authors}) {
            if (matches($author, $pattern)) {
                push(@result, $idx);
            }
            $idx++;
        }

    }

    # Потрібно залишити унікальні індекси
    my %seen = ();
    my @unique = grep { ! $seen{$_}++ } @result;

    return \@unique;
}

=head2 inject_REST($pattern)

Інкапсулює об'єкти L<Data::Match> структури для м'якого пошуку методом C<matches>.
Повертає клон структури з інкапсульованими методами C<REST>.

=cut

sub inject_REST {
    my $pattern = clone(shift);
    my @queue = ($pattern);
    my %seen = ();

    my %WALK = (
        HASH => sub {
            my ($obj) = @_;
            foreach (keys %{$obj}) {
                push @queue, $obj->{$_};
            }
            $obj->{REST()} = REST();
        },
        ARRAY => sub {
            my ($obj) = @_;
            foreach (@{$obj}) {
                push @queue, $_;
            }
            push(@{$obj}, REST());
        }
    );

    while (my $obj = shift @queue) {
        my $ref = ref $obj;
        if ($ref && ($ref eq 'ARRAY' or $ref eq 'HASH')) {
            $WALK{$ref}->($obj)
                unless ($seen{refaddr $obj}++);
        }
    }

    return $pattern;
}

=head2 update_authors

=cut

sub update_authors {
    my ($authors, $params) = @_;

    my $data = get_curl_data($url_template_categoryinfo, $params);
    check_wiki_data($data, 'query');

    my @pageids = keys %{$data->{query}->{pages}};

    if ($pageids[0] == -1) {
        warn "Wiki: Category '".$params->{titles}."' not found\n";
        warn "Exit with code -1";
        exit -1;
    }

    my $members = get_categorymembers({
        lang     => $params->{lang},
        cmpageid => $data->{query}->{pages}->{$pageids[0]}->{pageid}});

    # Запитуємо список перекладів назви категорії
    my $tags = get_page_langs({
        lang   => $params->{lang},
        pageid => $data->{query}->{pages}->{$pageids[0]}->{pageid}});
    $tags->{name}->{$params->{lang}} = $data->{query}->{pages}->{$pageids[0]}->{title};
    foreach my $lang (keys %{$tags->{name}}) {
        $tags->{name}->{$lang} =~ s/^.*\:(.*)$/$1/;
    }

    foreach my $member (keys %{$members}) {

        # Шукаємо в $authors[] по імені, по всіх відомих мовах
        my $author_idx;
        foreach my $lang (keys %{$members->{$member}->{name}}) {
            if (exists $authors_index->{$lang}->{$members->{$member}->{name}->{$lang}}) {
                $author_idx = $authors_index->{$lang}->{$members->{$member}->{name}->{$lang}};
                last;
            }
        }
        if (defined $author_idx) {
            # Якщо знайшли, то додаємо всі поля, яких немає в $authors[]

            my $merged = merge($members->{$member}, $authors->[$author_idx]);

            # Перевіряємо і додаємо категорію за необхідності,
            # бо вона не додається методом Hash::Merge::Simple->merge()
            my $is_tagged = 0;
            foreach my $tag (@{$merged->{tags}}) {
                if ($tag->{$params->{lang}} eq $tags->{name}->{$params->{lang}}) {
                    $is_tagged++;
                    last;
                }
            }
            push(@{$merged->{tags}}, $tags->{name})
                unless $is_tagged;

            $authors->[$author_idx] = $merged;
        } else {
            # Якщо не знайшли, то додаємо в $authors

            # Додаємо категорію, за якою шукали у теги
            push(@{$members->{$member}->{tags}}, $tags->{name});

            push(@{$authors}, $members->{$member});
        }
    }
}

=head2 get_categorymembers

=cut

sub get_categorymembers {
    my ($params) = @_;
    my $members = {};
    my $data;

    do {
        $params->{cmcontinue} = $data->{continue}->{cmcontinue}
            if exists $data->{continue};
        $data = get_curl_data(
            $url_template_categorymembers,
            $params);

        my @pageids = map { $_->{pageid} } @{$data->{query}->{categorymembers}};

        # Запитуємо список імен і посилання на wiki для даної мови
        get_author_info($members, {
                lang    => $params->{lang},
                pageids => join('|', @pageids)});

        # Запитуємо список імен і посилання на wiki для інших мов
        foreach my $pageid (@pageids) {
            my $result = get_page_langs({
                    lang   => $params->{lang},
                    pageid => $pageid});
            if (exists $result->{name}) {
                foreach my $lang (keys %{$result->{name}}) {
                    $members->{$pageid}->{name}->{$lang} = $result->{name}->{$lang};
                    $members->{$pageid}->{wiki}->{$lang} = $result->{wiki}->{$lang};
                }
            }
        }

    } until (!exists $data->{continue});

    return $members;
}

=head2 get_author_info

=cut

sub get_author_info {
    my ($result, $params) = @_;

    my $data = get_curl_data(
            $url_template_info_url,
            $params
        );
    check_wiki_data($data, 'query');

    foreach my $pageid (keys %{$data->{query}->{pages}}) {
        $result->{$pageid}->{name}->{$params->{lang}} = $data->{query}->{pages}->{$pageid}->{title};
        $result->{$pageid}->{wiki}->{$params->{lang}} = $data->{query}->{pages}->{$pageid}->{fullurl};
    }
}

=head2 get_page_langs

=cut

sub get_page_langs {
    my ($params) = @_;
    my $result;

    my $data = get_curl_data(
            $url_template_langlinks,
            $params);

    foreach my $langlink (@{$data->{parse}->{langlinks}}) {
        foreach my $l (@langs) {
            if ($langlink->{lang} eq $l) {
                $result->{name}->{$l} = unescape($langlink->{'*'});
                $result->{wiki}->{$l} = $langlink->{url};
                last;
            }
        }
    }

    return $result;
}

=head2 init_curl

=cut

sub init_curl {
    $curl = new WWW::Curl::Easy->new;
    $curl->setopt(CURLOPT_FOLLOWLOCATION, 1);
    $curl->setopt(CURLOPT_COOKIEFILE, '');
    $curl->setopt(CURLOPT_COOKIEJAR, '');
    $curl->setopt(CURLOPT_USERAGENT, 'sharedBooks/0.0.1 (http://SB.TLD/; levonet@gmail.com)');
}

=head2 get_curl_data

=cut

sub get_curl_data {
    my ($url_template, $params) = @_;
    my $url = $url_template;

    foreach my $key (keys %{$params}) {
        my $value = uri_escape($params->{$key});
        if ($url =~ m/\{$key\}/) {
            $url =~ s/^(.*)\{$key\}(.*)$/$1$value$2/;
        } else {
            $url .= '&'.$key.'='.$value;
        }
    }

    my $datajson;
    $curl->setopt(CURLOPT_URL, $url);
    $curl->setopt(CURLOPT_WRITEDATA, \$datajson);
    my $retcode = $curl->perform;
    my $httpcode = $curl->getinfo(CURLINFO_HTTP_CODE);

    if ($retcode) {
        warn "cURL Error: ".$curl->strerror($retcode).". ".$curl->errbuf."\n";
        warn "Exit with code ".$retcode;
        exit $retcode;
    }

    my $data = JSON->new->utf8->decode($datajson);
    check_wiki_error($data);

    return $data;
}

=head2 check_wiki_error

=cut

sub check_wiki_error {
    my ($data) = @_;

    if (exists $data->{error}) {
        warn "Wiki Error: ".$data->{error}->{code}.". ".$data->{error}->{info}."\n";
        warn "Exit with code -1";
        exit -1;
    }
}

=head2 check_wiki_data

=cut

sub check_wiki_data {
    my ($data, $test) = @_;

    if (!exists $data->{$test} && exists $data->{warnings}) {
        warn "Wiki Warnings: ".$data->{warnings}->{main}->{'*'}."\n";
        warn "Exit with code -1";
        exit -1;
    }
}

=head2 unescape

=cut

sub unescape {
    my $src = shift;
    $src =~ s/\\x\{(.{2})\}/chr hex $1/eg;
    return $src;
}

1;

=head1 AUTHOR

Pavlo Bashyński E<lt>levonet {at} gmail {dot} comE<gt>

=head1 LICENSE

This is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
